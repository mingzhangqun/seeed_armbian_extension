# 7. Tools and CI

The utility belt around the firmware: offline FIT re-signing, the deb
release chain, CI builds. The always-on hardening features live in
[08-hardening.md](08-hardening.md).

1. [repack-fit.sh — offline FIT re-signing](#1-repack-fitsh--offline-fit-re-signing)
2. [Deb packaging and release chain](#2-deb-packaging-and-release-chain)
3. [CI builds (Images Build workflow)](#3-ci-builds-images-build-workflow)

## 1. repack-fit.sh — offline FIT re-signing

[`scripts/repack-fit.sh`](../scripts/repack-fit.sh) rebuilds a signed kernel
FIT from an **existing** `boot.itb` — extract components, apply a new dtbo
list, re-sign with the same RSA key. No Armbian rebuild, no build tree
needed. Typical use: change the device-tree overlay set of a secure-boot
image ([why overlays need this](06-secure-boot.md#5-device-tree-overlays-on-secure-boot-images)).

```bash
./scripts/repack-fit.sh \
  --source-boot-itb boot.itb \
  --dtbo-list 'overlays/uart7-m2.dtbo' \
  --linux-source <linux-source-tree> \
  --u-boot-dir <u-boot-workdir-with-keys> \
  --keys-source-dir <fit-keys-dir> \
  --boot-soc rk3576 \
  --output boot-new.itb
# then dd boot-new.itb to the raw boot partition (carefully — verify the target!)
```

Required: the seven options above. Useful optional flags: `--bootargs`
(defaults to the source FIT's), `--rkbin-dir` (prebuilt mkimage location,
auto-detected from the Armbian cache), `--docker-image` (sign inside a
specific image), `--cache-dir`/`--no-cache`, `--keep-workdir`.

Safety rails: it refuses to re-sign the build-time staging artifact in
place; it prefers the Rockchip prebuilt `mkimage` for signing (the
[PSS salt pitfall](06-secure-boot.md#4-the-mkimage-pss-salt-pitfall)) and
warns before falling back to a tree mkimage; the result is verified with
`fit_check_sign` when available.

## 2. Deb packaging and release chain

Three scripts, normally driven by CI ([below](#3-ci-builds-images-build-workflow)):

| Script | Purpose |
|---|---|
| [`build-all-debs.sh`](../scripts/build-all-debs.sh) | Build the five board debs (FCS960K AI camera, Morse WiFi tools, USB gadget) into an output dir |
| [`generate-deb-index.sh`](../scripts/generate-deb-index.sh) | Generate the repository index HTML (categories, apt usage snippets, stats) |
| [`publish-aptly.sh`](../scripts/publish-aptly.sh) | Publish debs into an aptly repo (`stable`/`main`/arm64), export the GPG key — requires `ARMBIAN_APT_GPG_KEY_ID` |

Local use example:

```bash
./scripts/build-all-debs.sh out/debs
ARMBIAN_APT_GPG_KEY_ID=<gpg-key-id> ./scripts/publish-aptly.sh out/debs
```

## 3. CI builds (Images Build workflow)

[`.github/workflows/build-images.yml`](../.github/workflows/build-images.yml)
builds firmware on GitHub Actions — useful when you want images without a
local build environment.

**Trigger**: Actions → *Images - Build & Pre-release* → *Run workflow*. Select via checkboxes:

- boards (rk3576 / rk3588 / rk3576 module devkits), releases (trixie / resolute), tier (cli / mid)
- OTA mode (recovery / ab), security (plain / **secure-boot**)
- desktop environment, full/minimal mode, extension ref (default `main`)

Repository secrets — a preflight job validates everything your selection
needs **before** the multi-hour build starts:

| Secret | Purpose | Required when |
|---|---|---|
| `PRIVATE_KEY_PEM` | FIT signing private key; staged into `cache/sources/fit-keys` and fed to the build via `UBOOT_FIT_KEYS_BACKUP_DIR` ([06 §3](06-secure-boot.md#3-signing-keys-keep-them-or-regenerate-them)) | `secure-boot` |
| `DEV_CRT` | matching signing certificate (`dev.crt`); preflight checks it matches the private key | `secure-boot` |
| `CRYPTROOT_PASSPHRASE` | LUKS rootfs passphrase, exactly 64 *hex* characters ([05](05-encryption.md)); preflight checks length only | `secure-boot` |
| `RELEASE_GH_TOKEN` | GitHub token for publishing the Release to a different `release_repo`; falls back to the workflow's own token | cross-repo `release_repo` |
| `RCLONE_CONFIG` | rclone remote config for the OneDrive upload; without it the run falls back to GitHub-release assets (fork mode) | OneDrive mode |

Every run creates a draft pre-release in `release_repo` (a same-tag release
from a re-run is deleted first). With `RCLONE_CONFIG` set, image/OTA
binaries are uploaded to the OneDrive mirror's slot-first tree

```
armbian/images/<slot>/<board>/<profile>[-secure-boot]/{*.img.xz,*.sha256,ota/}
```

where `<slot>` is `pre-release`, `latest` or `previous`, and the release
carries **no assets at all** — the slot's `tag` file is the build
signature. The promote workflow validates that the tag file names the
release being promoted and that every `<board>/<sub>/` on the mirror is
complete (≥1 image with `.sha256` siblings, non-empty `ota/`, no
strays). Once every matrix entry has uploaded, the release
job stamps the build's tag into `pre-release/tag` — that file is the
page's slot binding — and flips the release visible. Promoting rotates
the whole slot tree with one server-side move per slot
(`previous ⟵ latest ⟵ pre-release`, all boards together) and carries the
`tag` file into `latest/`/`previous/` with it. Without `RCLONE_CONFIG`
(fork mode), the binaries are attached to the release itself — a file
over GitHub's 2 GiB asset cap fails the upload and needs an OneDrive-mode
run to ship. Download tables for the published slots live on the Pages
download page. Promoting cleans up superseded asset-less pre-releases
(binaries in slots, no release assets), keeping the releases page clean.
`Pages - Refresh` (`refresh-pages.yml`) is a dispatch-only re-render of
the page against the live mirror — reach for it after manual OneDrive
cleanup.

Everything CI does is the documented local flow — the wrapper staging step,
profiles, and secrets map 1:1 to [02-build-reference.md](02-build-reference.md).
