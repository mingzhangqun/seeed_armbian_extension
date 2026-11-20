#!/usr/bin/env python3
"""Reconcile the tag-addressed image mirror with slots.json and Releases."""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from image_mirror_common import (
    ImageMirrorError,
    command,
    decode,
    kernel_repo_from_notes,
    parse_slots,
    pipeline_owned,
    references,
)

# Backwards-compatible names for the workflow error handler and unit tests.
ReconcileError = ImageMirrorError


EXPIRED_NOTE = (
    "Mirror retention exceeded: the OneDrive image tree for this release "
    "has been removed to save space. This GitHub Release and its immutable "
    "version tag are retained as historical metadata; no mirror download "
    "is available for this tag."
)


class Mirror:
    def __init__(self, base, runner=command):
        self.base = base
        self.runner = runner

    def call(self, *args, input=None):
        return self.runner("rclone", [*args, "--contimeout", "15s"], input=input)

    def cat(self, path):
        return self.call("cat", f"{self.base}/{path}")

    def json(self, path):
        return decode(self.cat(path), path)

    def dirs(self, path):
        value = decode(
            self.call("lsjson", "--dirs-only", f"{self.base}/{path}"), path
        )
        if not isinstance(value, list) or any(not isinstance(v, dict) for v in value):
            raise ReconcileError(f"{path}: invalid directory listing")
        return [v.get("Path") for v in value]

    def files(self, tag):
        value = decode(
            self.call("lsjson", "-R", "--files-only", f"{self.base}/trees/{tag}"),
            f"trees/{tag}",
        )
        if not isinstance(value, list) or any(not isinstance(v, dict) for v in value):
            raise ReconcileError(f"trees/{tag}: invalid file listing")
        return [v.get("Path") for v in value]

    def slots(self):
        slots = parse_slots(self.cat("slots.json"))
        # Reconcile canonicalizes legacy history before its compare-and-swap.
        slots["history"] = list(dict.fromkeys(slots["history"]))
        return slots

    def write_slots(self, expected, desired):
        # Detect out-of-band edits; OneDrive offers no compare-and-swap write.
        if self.slots() != expected:
            raise ReconcileError(
                "slots.json changed during reconcile; refusing to overwrite it"
            )
        self.call(
            "rcat", f"{self.base}/slots.json",
            input=json.dumps(desired, indent=1, sort_keys=True) + "\n",
        )

    def validate_tree(self, tag):
        errors = []
        try:
            files = self.files(tag)
            manifest = self.json(f"trees/{tag}/manifest.json")
        except ReconcileError as exc:
            raise ReconcileError(f"referenced tree {tag} is invalid: {exc}") from exc
        by_kind, boards = {}, set()
        for path in files:
            if not isinstance(path, str):
                errors.append("file listing contains a non-string path")
                continue
            if path == "manifest.json":
                continue
            parts = path.split("/")
            if len(parts) < 2:
                errors.append(f"stray file at trees/{tag} root: {path}")
                continue
            board, security = parts[:2]
            if security not in ("plain", "secure"):
                errors.append(f"{board}: expected plain|secure: {path}")
                continue
            boards.add(board)
            if len(parts) < 4 or parts[2] not in ("recovery", "ab", "loaders"):
                errors.append(f"{board}/{security}: invalid kind/path: {path}")
                continue
            by_kind.setdefault((board, security, parts[2]), []).append(
                "/".join(parts[3:])
            )
        if not any(key[2] in ("recovery", "ab") for key in by_kind):
            errors.append("holds no recovery/ab image content")
        for (board, security, kind), names in by_kind.items():
            if kind == "loaders":
                continue
            images = [name for name in names if name.endswith(".img.xz")]
            if not images:
                errors.append(f"{board}/{security}/{kind}: no .img.xz")
            for image in images:
                if image + ".sha256" not in names:
                    errors.append(f"{board}/{security}/{kind}/{image}: no .sha256")
            if not any(name.startswith("ota/") for name in names):
                errors.append(f"{board}/{security}/{kind}: no OTA payload")
        if not isinstance(manifest, dict) or manifest.get("tag") != tag:
            errors.append(f"manifest tag does not match {tag}")
        manifest_files = manifest.get("files") if isinstance(manifest, dict) else None
        if not isinstance(manifest_files, dict) or not manifest_files:
            errors.append("manifest files must be a non-empty object")
            manifest_files = {}
        walked = set(files) - {"manifest.json"}
        for path in sorted(walked - set(manifest_files)):
            errors.append(f"manifest missing entry for {path}")
        for path in sorted(set(manifest_files) - walked):
            errors.append(f"manifest entry {path} is not on the mirror")
        if any(not isinstance(url, str) or not url for url in manifest_files.values()):
            errors.append("manifest holds an empty or non-string URL")
        if errors:
            raise ReconcileError(
                f"referenced tree {tag} is invalid:\n  " + "\n  ".join(errors)
            )
        print(
            f"tree OK: {tag}, {len(boards)} boards, {len(by_kind)} directories, "
            f"{len(manifest_files)} links"
        )

    def validate(self, slots):
        for tag in references(slots):
            self.validate_tree(tag)

    def gc(self, expected):
        # Do not sweep using stale references after an out-of-band slot edit.
        current = self.slots()
        if current != expected:
            raise ReconcileError("slots.json changed before GC; no trees were purged")
        # One reread narrows the write/GC race; OneDrive has no atomic CAS.
        for directory in self.dirs(""):
            if directory not in ("pre-release", "stable", "previous"):
                continue
            if self.slots() != expected:
                raise ReconcileError("slots.json changed during GC; stopping before legacy purge")
            self.purge(f"{self.base}/{directory}")
        for tag in self.dirs("trees"):
            if tag in references(current):
                continue
            if self.slots() != expected:
                raise ReconcileError(
                    f"slots.json changed during GC; preserving tree {tag}"
                )
            print(f"purging expired mirror tree {tag}; retaining its GitHub Release")
            self.purge(f"{self.base}/trees/{tag}")

    def purge(self, path):
        # OneDrive keeps purged items in the recycle bin, still counted
        # against quota. --onedrive-hard-delete (rclone >= 1.67, drive_type
        # business) issues a Graph permanentDelete so the space is freed.
        self.call("purge", path, "--onedrive-hard-delete")


class Releases:
    def __init__(self, repo, workflow_repo, runner=command):
        self.repo = repo
        self.workflow_repo = workflow_repo
        self.runner = runner

    def call(self, *args, input=None):
        # gh api reads GH_REPO (set by promote-images.yml); --repo belongs
        # to gh release, not gh api. Local runs may set GH_REPO likewise.
        return self.runner("gh", args, input=input)

    def api(self, method, endpoint, payload=None):
        args = ["api", "--method", method, endpoint]
        input = None
        if payload is not None:
            args += ["--input", "-"]
            input = json.dumps(payload)
        return decode(self.call(*args, input=input), endpoint)

    def view(self, tag, fields):
        return decode(
            self.call("release", "view", tag, "--json", ",".join(fields)),
            f"Release {tag}",
        )

    def validate_promotion(self, tag, release_list):
        # Validate the original prerelease before retiring its mirror pointer.
        # A successful retry moves this prerelease to stable after the
        # mirror pointers have been validated, so it cannot be mistaken for
        # an incomplete candidate on a later reconciliation.
        release = next(
            (release for release in release_list if release["tagName"] == tag), None
        )
        if release is None:
            raise ReconcileError(f"candidate {tag} has no GitHub Release")
        if not release["isPrerelease"] or release["isDraft"]:
            raise ReconcileError(
                f"candidate Release {tag} is not a published prerelease"
            )
        state = self.view(tag, ["id", "isDraft", "isPrerelease"])
        if state["isDraft"] or not state["isPrerelease"]:
            raise ReconcileError(
                f"candidate Release {tag} is not a published prerelease"
            )

    def publish_stable(self, tag):
        state = self.view(tag, ["id", "isDraft", "isPrerelease"])
        if state["isDraft"] and not state["isPrerelease"]:
            raise ReconcileError(f"candidate {tag} is a draft stable Release")
        self.call(
            "release", "edit", tag, "--draft=false", "--prerelease=false",
            "--latest=false", "--verify-tag",
        )
        state = self.view(tag, ["id", "isDraft", "isPrerelease"])
        if state["isDraft"] or state["isPrerelease"]:
            raise ReconcileError(f"Release {tag} did not become a stable Release")
        return state["id"]

    def mark_latest(self, tag):
        # gh release view's id is a GraphQL node ID. The REST endpoint
        # requires the numeric databaseId, which is available in list().
        release = next((r for r in self.list() if r["tagName"] == tag), None)
        if release is None:
            raise ReconcileError(f"no Release found for {tag}")
        self.api("PATCH", f"repos/{self.repo}/releases/{release['databaseId']}",
                 {"make_latest": "true"})
        latest = self.api("GET", f"repos/{self.repo}/releases/latest")
        if latest.get("tag_name") != tag:
            raise ReconcileError(
                f"GitHub Latest is {latest.get('tag_name')!r}, expected stable {tag!r}"
            )

    def list(self):
        # --paginate emits one JSON object per line with --jq, not a JSON array.
        raw = self.call(
            "api", "--paginate", f"repos/{self.repo}/releases?per_page=100",
            "--jq", ".[] | {tagName: .tag_name, databaseId: .id, isDraft: .draft, "
                    "isPrerelease: .prerelease, isStable: ((.draft | not) "
                    "and (.prerelease | not))}",
        )
        return [decode(line, "Release list") for line in raw.splitlines() if line.strip()]

    def remove_dangling(self, tag, releases):
        if tag not in {release["tagName"] for release in releases}:
            return
        state = self.view(tag, ["isDraft", "isPrerelease", "assets", "body"])
        if state["isDraft"] or not state["isPrerelease"] or state["assets"]:
            print(f"keeping {tag}: draft, stable, or has assets")
            return
        owned = pipeline_owned(state["body"] or "", self.workflow_repo)
        if not owned:
            print(f"keeping {tag}: not owned by this pipeline")
            return
        self.call("release", "delete", tag, "--yes", "--cleanup-tag")

    def gc_stale_drafts(self, slots, releases, age_days=90):
        # A cancelled or re-run-all'd attempt can leave an owned, asset-less
        # draft Release with no slots.json pointer (retire keys on the
        # pointer, so nothing replaces it). Sweep those past the failed-job
        # rerun window — runs stay re-runnable for the whole retention
        # period (90 days default) and a failed-job rerun never re-runs the
        # already-successful draft-creation step — together with their
        # source tags. Re-run-all recreates its draft via the create-step
        # replace block.
        referenced = references(slots)
        now = datetime.now(timezone.utc)
        for release in releases:
            tag = release["tagName"]
            if not release["isDraft"] or tag in referenced:
                continue
            state = self.view(tag, ["createdAt", "assets", "body"])
            if state["assets"]:
                print(f"keeping draft {tag}: it holds assets")
                continue
            body = state["body"] or ""
            if not pipeline_owned(body, self.workflow_repo):
                print(f"keeping draft {tag}: not owned by this pipeline")
                continue
            created = datetime.fromisoformat(
                state["createdAt"].replace("Z", "+00:00")
            )
            if (now - created).days < age_days:
                print(f"keeping draft {tag}: within the rerun-resume window")
                continue
            # Drafts were never published, so no release-repo tag exists yet;
            # --cleanup-tag would target a missing ref and, if gh treats that
            # as failure, abort the run after the draft is already gone and
            # before the source-tag sweep. The release repo is swept with the
            # same tolerate-missing loop below instead.
            self.call("release", "delete", tag, "--yes")
            kernel_repo = kernel_repo_from_notes(body)
            for repo in [self.workflow_repo, self.repo] + (
                [kernel_repo] if kernel_repo else []
            ):
                try:
                    self.api("DELETE", f"repos/{repo}/git/refs/tags/{tag}")
                except ReconcileError:
                    pass  # the ref is already absent (or not ours to touch)
            print(f"gc: removed stale draft {tag} and its source tags")

    def reconcile_history(self, slots, releases):
        referenced = references(slots)
        available = {release["tagName"] for release in releases}
        missing = [tag for tag in referenced if tag not in available]
        if missing:
            raise ReconcileError(
                f"referenced mirror trees lack GitHub Releases: {', '.join(missing)}"
            )
        for release in releases:
            tag = release["tagName"]
            if tag == slots["stable"]:
                continue
            if tag == slots["pre-release"]:
                if not release["isPrerelease"] or release["isDraft"]:
                    raise ReconcileError(
                        f"candidate Release {tag} is not a published prerelease"
                    )
                continue
            if tag in slots["history"]:
                # A history Release cannot be prerelease: stable -> history
                # is a state transition, not merely a slots pointer change.
                if release["isPrerelease"] or release["isDraft"]:
                    self.publish_stable(tag)
                continue
            if not release["isStable"]:
                continue
            body = self.view(tag, ["body"])["body"] or ""
            if EXPIRED_NOTE in body:
                continue
            self.call(
                "release", "edit", tag, "--notes-file", "-",
                input=body.rstrip() + "\n\n" + EXPIRED_NOTE + "\n",
            )
            print(f"marked expired mirror retention on retained Release {tag}")


def reconcile(mirror, releases, depth=0):
    if depth < 0:
        raise ReconcileError("HISTORY_DEPTH must be >= 0")
    old = mirror.slots()
    stable, candidate = old["stable"], old["pre-release"]
    if not any([candidate, stable, *old["history"]]):
        # The build workflow may initialize an empty pointer file before its
        # first upload. Treat that state as a no-op: promotion cannot create a
        # Release from nothing and must never use emptiness as a GC license.
        print("mirror has no published pointers; nothing to reconcile")
        return {"tag": "", "mode": "empty"}
    release_list = releases.list()
    available = {release["tagName"] for release in release_list}
    # Check tree existence before discarding a missing candidate pointer;
    # treeless candidates need remove_dangling's ownership checks below.
    repaired = None
    tree_dirs = mirror.dirs("trees")
    candidate_tree_missing = bool(candidate and candidate not in tree_dirs)
    missing_history = sorted(
        tag for tag in old["history"] if tag not in tree_dirs
    )
    # Repair a deleted Release before rotating the candidate to stable;
    # otherwise an old stable is pushed into history while losing its tag.
    missing = sorted(tag for tag in references(old) if tag not in available)
    missing_candidate = candidate if candidate and candidate not in available else None
    if missing and (not candidate or missing_candidate):
        old = {
            "stable": stable if stable in available else None,
            "pre-release": candidate if candidate in available else None,
            "history": [tag for tag in old["history"] if tag in available],
        }
        print(f"clearing mirror pointers with no GitHub Release: {', '.join(missing)}")
        stable, candidate = old["stable"], old["pre-release"]
        mirror.validate(old)
        current = mirror.slots()
        if old != current:
            mirror.write_slots(current, old)
        releases.reconcile_history(old, release_list)
        if missing_candidate and candidate_tree_missing:
            repaired = missing_candidate
            candidate = None
    if candidate:
        # Enumerate the parent, rather than inferring absence from error text.
        if candidate_tree_missing:
            repaired = candidate or repaired
            print(f"candidate {candidate} has no tree; clearing its dangling pointer")
            candidate = None
            mode = "reconcile"
        else:
            mode = "promote"
    else:
        mode = "reconcile"
    promoted = candidate if mode == "promote" else None
    stable = promoted or stable
    if missing_history:
        print(f"clearing pointers to missing history trees: {', '.join(missing_history)}")
    history = [old["stable"], *old["history"]] if promoted else old["history"]
    history = list(dict.fromkeys(
        tag for tag in history
        if tag and tag != stable and tag not in missing_history
    ))[:depth]
    desired = {
        "stable": stable,
        "pre-release": None if promoted else candidate,
        "history": history,
    }
    # If the previous attempt already moved the candidate to stable, the
    # empty pre-release slot lets this run finish Release and GC idempotently.
    mirror.validate(desired)
    if promoted:
        releases.validate_promotion(promoted, release_list)
    # A deleted Release must not leave its tag permanently exposed on the
    # download page. Keep only references backed by a Release; GC then
    # reclaims the now-unreferenced trees, not a retained stable/history tree.
    available = {release["tagName"] for release in release_list}
    missing = sorted(tag for tag in references(desired) if tag not in available)
    if missing:
        desired = {
            "stable": desired["stable"] if desired["stable"] in available else None,
            "pre-release": desired["pre-release"] if desired["pre-release"] in available else None,
            "history": [tag for tag in desired["history"] if tag in available],
        }
        print(f"clearing mirror pointers with no GitHub Release: {', '.join(missing)}")
        releases.reconcile_history(desired, release_list)
        if desired != old:
            mirror.write_slots(old, desired)
        mirror.gc(desired)
        if repaired:
            releases.remove_dangling(repaired, release_list)
        stable = desired["stable"]
        if stable:
            releases.publish_stable(stable)
            releases.mark_latest(stable)
        return {"tag": stable or "", "mode": "reconcile"}
    if repaired:
        if desired != old:
            mirror.write_slots(old, desired)
        # Clean legacy directories independently of whether a stable exists.
        for directory in mirror.dirs(""):
            if directory in ("pre-release", "stable", "previous"):
                mirror.purge(f"{mirror.base}/{directory}")
        mirror.gc(desired)
        releases.remove_dangling(repaired, release_list)
        releases.reconcile_history(desired, release_list)
        return {"tag": stable or "", "mode": mode}
    if desired != old:
        mirror.write_slots(old, desired)
    if stable:
        releases.publish_stable(stable)
        releases.mark_latest(stable)
    mirror.gc(desired)
    releases.reconcile_history(desired, releases.list())
    releases.gc_stale_drafts(desired, releases.list())
    return {"tag": stable or "", "mode": mode}


def main():
    if not os.environ.get("RCLONE_CONFIG"):
        raise ReconcileError("RCLONE_CONFIG is not set; promotion requires OneDrive")
    owner = os.environ["GITHUB_REPOSITORY_OWNER"].lower()
    repo = f"{os.environ['GITHUB_REPOSITORY_OWNER']}/armbian-build"
    mirror = Mirror(f"seeed-storage:armbian/{owner}/images")
    releases = Releases(repo, os.environ["GITHUB_REPOSITORY"])
    result = reconcile(
        mirror, releases,
        int(os.environ.get("HISTORY_DEPTH", "0")),
    )
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with Path(output).open("a") as stream:
            for key, value in {**result, "target_repo": repo}.items():
                print(f"{key}={value}", file=stream)
    print(f"reconciled {result['mode']}: stable={result['tag'] or '<empty>'}")


if __name__ == "__main__":
    try:
        main()
    except (ReconcileError, KeyError, ValueError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        sys.exit(1)
