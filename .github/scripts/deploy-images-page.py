#!/usr/bin/env python3
"""Validate the mirror manifest and assemble the images page data bundle."""

import json
import os
import subprocess
import sys
import time

from image_mirror_common import ImageMirrorError, decode, parse_slots

DeployError = ImageMirrorError


def rcall(what, args, retries=1):
    """Run one rclone invocation; retry once on error, return its stdout."""
    result = None
    for attempt in range(retries + 1):
        try:
            result = subprocess.run(
                ["rclone", *args, "--contimeout", "15s"],
                capture_output=True, text=True, timeout=120,
            )
        except subprocess.TimeoutExpired:
            result = None
        else:
            if result.returncode == 0:
                return result.stdout
        if attempt < retries:
            time.sleep(5)
    error = result.stderr.strip() if result is not None else "exceeded 120 seconds"
    raise DeployError(f"rclone failed for {what}: {error}")


def rcat(path, retries=1):
    return rcall(path, ["cat", path], retries=retries)


def tree_dirs(base):
    listing = decode(
        rcall(f"{base}/trees", ["lsjson", "--dirs-only", f"{base}/trees"]),
        "trees/",
    )
    if (not isinstance(listing, list)
            or any(not isinstance(entry, dict)
                   or not isinstance(entry.get("Path"), str)
                   or not entry["Path"] or "/" in entry["Path"]
                   for entry in listing)):
        raise DeployError("trees/: invalid directory listing")
    return {entry["Path"] for entry in listing}


def tree_file_sizes(base, tag):
    """Read download sizes without changing the immutable per-tag manifest."""
    listing = decode(
        rcall(f"trees/{tag}", ["lsjson", "-R", "--files-only", f"{base}/trees/{tag}"]),
        f"trees/{tag}/",
    )
    if not isinstance(listing, list):
        raise DeployError(f"trees/{tag}: invalid file listing")
    sizes = {}
    for entry in listing:
        if (not isinstance(entry, dict) or not isinstance(entry.get("Path"), str)
                or not entry["Path"] or type(entry.get("Size")) is not int
                or entry["Size"] < 0):
            raise DeployError(f"trees/{tag}: invalid file size entry")
        if entry["Path"] != "manifest.json":
            sizes[entry["Path"]] = entry["Size"]
    return sizes


def read_mirror(base):
    slots_in = parse_slots(rcat(f"{base}/slots.json"), legacy=False)
    stable, candidate, history = slots_in["stable"], slots_in["pre-release"], slots_in["history"]
    if not any([stable, candidate, *history]):
        # Normalization always supplies all three keys. Check their values so a
        # valid empty pointer file cannot replace a working page with no links.
        raise DeployError("slots.json has no published image tree pointers")

    manifests, page_slots = {}, {}

    def take(tag, optional=False):
        try:
            manifest = decode(
                rcat(f"{base}/trees/{tag}/manifest.json"),
                f"trees/{tag}/manifest.json",
            )
        except DeployError as exc:
            if not optional:
                raise
            # An expired history tree can leave a file-shaped parent entry;
            # rclone lsjson may list it even though no manifest is readable.
            print(
                f"::warning::history manifest {tag} is unreadable; "
                f"omitting its downloads: {exc}", file=sys.stderr,
            )
            return False
        if not isinstance(manifest, dict) or manifest.get("tag") != tag:
            actual = manifest.get("tag") if isinstance(manifest, dict) else None
            raise DeployError(
                f"trees/{tag}/manifest.json is signed {actual!r} — mismatch"
            )
        files = manifest.get("files")
        if not isinstance(files, dict) or not files:
            raise DeployError(
                f"trees/{tag}/manifest.json must have a non-empty files object"
            )
        if any(not isinstance(path, str) or not path or not isinstance(url, str) or not url
               for path, url in files.items()):
            raise DeployError(f"trees/{tag}/manifest.json has an invalid file link")
        if "sizes" in manifest:
            sizes = manifest["sizes"]
            if (not isinstance(sizes, dict) or set(sizes) != set(files)
                    or any(type(size) is not int or size < 0 for size in sizes.values())):
                raise DeployError(f"trees/{tag}/manifest.json has invalid file sizes")
        manifests[tag] = manifest
        return True

    # Only legacy manifests need a file walk; new manifests carry sizes.
    # The legacy tree stays untouched, and refresh enriches only data.json.
    def attach_sizes(tag):
        manifest = manifests[tag]
        if "sizes" in manifest:
            return
        sizes = tree_file_sizes(base, tag)
        if set(sizes) != set(manifest["files"]):
            raise DeployError(
                f"trees/{tag}: manifest and file listing differ; refusing to publish sizes"
            )
        manifest["sizes"] = sizes

    for slot, tag in (("pre-release", candidate), ("stable", stable)):
        if tag:
            take(tag)
            attach_sizes(tag)
            page_slots[slot] = tag
    seen = set()
    present_history = []
    # A history tree may have been deleted out of band or after retention.
    # Enumerate its parent instead of guessing from a backend error message.
    # Primary slots remain mandatory: never drop their links on a refresh.
    if history:
        present_trees = tree_dirs(base)
        for tag in history:
            if tag in seen or tag in (stable, candidate):
                raise DeployError(
                    f"slots.json history holds an invalid entry {tag!r} — "
                    "duplicate or primary-slot tag"
                )
            seen.add(tag)
            if tag not in present_trees:
                print(
                    f"::warning::history tree {tag} is absent; "
                    "omitting it from downloads while retaining its Release",
                    file=sys.stderr,
                )
                continue
            if take(tag, optional=True):
                attach_sizes(tag)
                present_history.append(tag)
    if present_history:
        page_slots["history"] = present_history
    return {"slots": page_slots, "manifests": manifests}


def gh(*args):
    last_error = None
    for attempt in range(3):
        try:
            result = subprocess.run(
                ["gh", *args], capture_output=True, text=True, timeout=120,
            )
        except subprocess.TimeoutExpired:
            last_error = "exceeded 120 seconds"
        else:
            if result.returncode == 0:
                return result.stdout
            last_error = result.stderr.strip() or "command failed"
        if attempt < 2:
            print(
                f"gh {' '.join(args)} failed (attempt {attempt + 1}/3), "
                f"retrying in {(attempt + 1) * 10}s", file=sys.stderr,
            )
            time.sleep((attempt + 1) * 10)
    raise DeployError(f"gh {' '.join(args)} failed after 3 attempts: {last_error}")


def release_metadata(release):
    if not isinstance(release, dict):
        raise DeployError("Release metadata must be a JSON object")
    try:
        tag = release["tag_name"]
        prerelease = release["prerelease"]
        published_at = release["published_at"]
    except KeyError as exc:
        raise DeployError(f"Release metadata lacks {exc.args[0]}") from exc
    if not isinstance(tag, str) or not tag or not isinstance(prerelease, bool):
        raise DeployError("Release metadata has an invalid tag or prerelease state")
    if published_at is not None and not isinstance(published_at, str):
        raise DeployError(f"Release {tag} has an invalid publication date")
    return {"tag_name": tag, "prerelease": prerelease, "published_at": published_at}


def read_releases(repo, referenced_tags):
    # Do not rely on the newest N releases: an older stable/history tag must
    # keep its real date and prerelease state on every refresh.
    releases = {}
    for tag in sorted(referenced_tags):
        raw = gh(
            "release", "view", tag, "--repo", repo,
            "--json", "tagName,isPrerelease,publishedAt",
        )
        release = decode(raw, f"Release {tag}")
        if not isinstance(release, dict) or release.get("tagName") != tag:
            raise DeployError(f"Release lookup returned the wrong tag for {tag}")
        releases[tag] = {
            "tag_name": release["tagName"],
            "prerelease": release["isPrerelease"],
            "published_at": release["publishedAt"],
        }

    # The page consumes a complete array; preserve all Releases, including
    # historical Releases whose mirror trees have exceeded retention.
    raw = gh(
        "api", "--paginate", f"repos/{repo}/releases?per_page=100",
        "--jq", ".[] | {tag_name: .tag_name, prerelease: .prerelease, "
                "published_at: .published_at}",
    )
    result = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        release = decode(line, "Release list")
        release = release_metadata(release)
        if release["tag_name"] not in referenced_tags:
            releases[release["tag_name"]] = release
    for tag in referenced_tags:
        if tag not in releases:
            raise DeployError(f"referenced mirror tag lacks GitHub Release: {tag}")
    result = [release_metadata(releases[tag]) for tag in sorted(releases)]
    return result


def assemble(repo, core, releases):
    data = {
        "repo": repo,
        "slots": core["slots"],
        "manifests": core["manifests"],
        "releases": releases,
    }
    with open("data.json", "w") as stream:
        json.dump(data, stream, separators=(",", ":"))
    print(
        f"data.json: repo={repo} slots={list(data['slots'])} "
        f"{len(data['manifests'])} manifests, {len(releases)} releases"
    )


def main():
    stage = sys.argv[1]
    if stage == "manifest":
        owner = os.environ["GITHUB_REPOSITORY_OWNER"].lower()
        core = read_mirror(f"seeed-storage:armbian/{owner}/images")
        with open("data-core.json", "w") as stream:
            json.dump(core, stream)
        count = sum(len(m.get("files") or {}) for m in core["manifests"].values())
        print(
            f"manifest: {len(core['slots'])} slot keys, "
            f"{len(core['manifests'])} manifests, {count} links total",
            file=sys.stderr,
        )
    elif stage == "data":
        repo = os.environ["PAGE_REPO"]
        if not repo:
            raise DeployError("PAGE_REPO empty")
        try:
            with open("data-core.json") as stream:
                core = json.load(stream)
        except FileNotFoundError as exc:
            raise DeployError(
                "missing mirror data-core.json — refusing to deploy an empty page"
            ) from exc
        tags = {core["slots"].get("stable"), core["slots"].get("pre-release")}
        tags.update(core["slots"].get("history", []))
        assemble(repo, core, read_releases(repo, tags - {None}))
    else:
        raise DeployError(f"unknown stage: {stage}")


if __name__ == "__main__":
    try:
        main()
    except (DeployError, KeyError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        sys.exit(1)
