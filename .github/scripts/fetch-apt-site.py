#!/usr/bin/env python3
"""Carry the live apt repository into a Pages deployment snapshot.

The extension repo's Pages site hosts two subtrees: the apt repository at
the root (published by apt-repo-publish) and the images page at images/.
GitHub Pages Actions deployments replace the WHOLE site, so every
deployment must include both subtrees. This script downloads the current
apt tree from the live site into a target directory, so the images
pipeline's snapshot preserves it (apt-repo-publish does the mirror image
for images/).

The apt file set is derived from the repository's own indexes: the
fixed dists metadata plus every pool file named by the Packages index.
A missing root (no apt repository deployed yet, e.g. the fork) is not
an error — nothing is fetched.
"""

import argparse
import sys
import urllib.error
import urllib.request
from pathlib import Path

# The aptly layout fixed by publish-aptly.sh: stable/main/binary-arm64.
FIXED_PATHS = [
    "index.html",
    "seeed-repo.gpg",
    "dists/stable/Release",
    "dists/stable/Release.gpg",
    "dists/stable/InRelease",
    "dists/stable/main/binary-arm64/Packages",
    "dists/stable/main/binary-arm64/Packages.gz",
]
PACKAGES_PATH = "dists/stable/main/binary-arm64/Packages"


def fetch(base, path, retries=2):
    url = f"{base.rstrip('/')}/{path}"
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                if response.status != 200:
                    raise OSError(f"HTTP {response.status}")
                return response.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if attempt == retries:
                raise
        except (OSError, urllib.error.URLError):
            if attempt == retries:
                raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("base", help="live site base URL, e.g. https://owner.github.io/repo/")
    parser.add_argument("target", help="snapshot directory to populate (e.g. site/)")
    args = parser.parse_args()
    target = Path(args.target)

    packages = fetch(args.base, PACKAGES_PATH)
    pool_paths = []
    if packages is not None:
        for line in packages.decode("utf-8", "replace").splitlines():
            if line.startswith("Filename:"):
                name = line.split(":", 1)[1].strip()
                if name and not name.startswith(("images/", "/")) and ".." not in name:
                    pool_paths.append(name)
        print(f"apt snapshot: {len(pool_paths)} pool files from the Packages index")
    else:
        print("apt snapshot: no Packages index on the live site — nothing to carry")

    fetched, total = 0, 0
    for path in FIXED_PATHS + pool_paths:
        body = fetch(args.base, path)
        if body is None:
            if path in FIXED_PATHS and path not in (PACKAGES_PATH,):
                continue  # optional metadata may legitimately be absent
            if packages is not None and path not in FIXED_PATHS:
                print(f"::warning::pool file missing on the live site: {path}")
            continue
        out = target / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(body)
        fetched += 1
        total += len(body)
    print(f"apt snapshot carried: {fetched} files, {total / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - surface as a workflow error
        print(f"::error::cannot carry the live apt site: {exc}", file=sys.stderr)
        sys.exit(1)
