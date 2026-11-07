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
| `RCLONE_CONFIG` | rclone remote config for OneDrive image publication | always |

Every run creates a draft pre-release in `release_repo` (a same-tag release
from a re-run is deleted first). **Image/OTA binaries upload only to
OneDrive; GitHub Release assets are not supported.** The Release remains
version metadata, a pre-release/stable marker, and a link to the build run.
The immutable mirror layout is tag-addressed:

```
armbian/<owner>/images/trees/<tag>/<board>/<plain|secure>/<recovery|ab|loaders>/
```

`slots.json` identifies the current pre-release, stable and history tags.
After all matrix entries upload, the release job creates a per-file share
link and writes them to `trees/<tag>/manifest.json`, then points
`slots.json.pre-release` at the tag and flips the Release visible.
Promotion validates the complete referenced trees, updates the pointers
(`stable ⟵ pre-release`, previous stable joins the bounded history), and
moves no image files. The OneDrive tree for an expired stable may be
purged, but its GitHub Release is retained as historical metadata.
`Pages - Refresh` (`refresh-pages.yml`) re-renders the page from the live
manifest state, for example after manual OneDrive cleanup.

Board u-boot **production loaders** live inside the same tag tree, at
`<board>/<plain|secure>/loaders/`.

`spl_loader_maskrom.bin` (maskrom flashing loader) exists for every board;
`rkspi_loader.img` (SPI NOR image) only for layouts that build one
(`BOOT_SUPPORT_SPI` boards — devkit today). `secure/` holds the signed
rebuilds (signed FIT, `rk_sign_tool`-signed loader) and never shares a
directory with `plain/`. Only the reference leg (cli/trixie/recovery)
uploads — the u-boot payload is identical across the other legs of the same
`board+security`. Promote only flips the tag pointers; loader files stay
inside their tag tree.

The download page renders them per board as a first-class **Loader** mode
box (chip icon, teal/orange buttons) at the top of each security group
(green PLAIN / red SECURE frames with inverted corner labels). All image
and loader links come from the tag's OneDrive manifest.

Everything CI does is the documented local flow — the wrapper staging step,
profiles, and secrets map 1:1 to [02-build-reference.md](02-build-reference.md).
