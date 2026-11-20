#!/usr/bin/env python3
"""CLI for the Release-notes metadata shared by workflows and reconcile.

Subcommands (body is read from stdin):
  kernel-repo            Print the kernel repo named by the build-sources
                         table, or nothing.
  pipeline-owned <repo>  Exit 0 when the body links a run of <repo>, else 1.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from image_mirror_common import kernel_repo_from_notes, pipeline_owned


def main():
    args = sys.argv[1:]
    if args == ["kernel-repo"]:
        repo_found = kernel_repo_from_notes(sys.stdin.read())
        if repo_found:
            print(repo_found)
    elif len(args) == 2 and args[0] == "pipeline-owned":
        sys.exit(0 if pipeline_owned(sys.stdin.read(), args[1]) else 1)
    else:
        sys.exit(f"usage: {sys.argv[0]} (kernel-repo | pipeline-owned <owner/repo>)")


if __name__ == "__main__":
    main()
