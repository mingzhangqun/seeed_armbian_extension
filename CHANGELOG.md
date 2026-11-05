# Changelog

All notable changes to the Seeed Armbian board support extensions are
documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — secure boot, OTA overhaul, boot-disk anchoring, CI

Covers the work against the initial import (merge base `9980aee`,
2026-07-02 → 2026-10-14).

### Added

#### Recovery OTA

- **Secure-boot rescue: dedicated `recovery` raw FIT partition.** Secure
  boot Recovery images now split the boot area in two: the existing raw FIT
  `boot` partition plus a new `PARTLABEL=recovery` partition (same size as
  boot) holding the **same signed boot.itb**, flashed at image build time
  (`rescue-artifacts.sh`) and booted by the new `ota_rescue_boot_fit` env
  script (vendor `boot_fit` command, `boot_fit_part recovery` — mirroring
  the A/B raw-fit slot boot, so FIT signature verification applies). The
  rescue dispatcher `ota_rescue_boot` now chains
  `ota_rescue_boot_fs || ota_rescue_boot_fit || distro_bootcmd` across the
  three env producers (build-time prefill, `fw_env_write_routing_set`, and
  the compiled-default-env U-Boot patch). The rescue partition is never
  touched by OTA. Layout:
  `[boot raw FIT][recovery raw FIT][security][rootfs LUKS+ext4][userdata LUKS+ext4]`.
- **Secure-boot OTA packages.** `package-create.sh` computes a `PAYLOAD_ID`
  for secure-boot recovery packages (identity over the rootfs tar + the
  boot.itb tree) and stamps the rootfs `installed-payload-id` marker —
  previously the secure branch shipped no `PAYLOAD_ID` and the build failed
  at `ota_write_package_env`. Device-side `recovery_assert_dual_tar` accepts
  the `boot.itb + boot.sha256` payload shape; the lazy last-good backup
  reads the signed FIT from the raw boot partition (exact FDT-header size)
  into `boot.tar.zst`, restoring through the existing
  `write_raw_boot_itb` path. The health service and the Rescue
  success-reconciliation skip the `/boot/payload-id` check on raw-fit
  layouts (stamped `/usr/share/armbian-ota/boot-mode`).
- **Dedicated `/boot` partition for all Recovery images.** Plain and
  auto-decrypt Recovery builds now reserve a separate ext4 boot partition
  (label `armbi_boot`); the initramfs mounts it on top of overlayfs,
  anchored to the rootfs disk (no `/boot` fstab entry — an fstab source is
  unresolvable on multi-disk clones). This
  fixes runtime writes to `/boot` (apt kernel upgrades, `armbianEnv.txt`
  edits, OTA tooling) being swallowed by the overlayfs upper layer on
  userdata and silently ignored by U-Boot on next boot. Secure-boot
  Recovery continues to use a raw FIT boot partition (`BOOT_RAW_MODE=yes`),
  unchanged. The partition order is now `[boot][recovery?][security?][rootfs][userdata]`.
- **`recurse=0` on overlayroot.** The overlayroot package's init-bottom
  hook defaults to `recurse=1`, which wraps every fstab mount point in a
  per-directory overlay — so even with a dedicated boot partition, `/boot`
  was still being overlayed and writes were captured by userdata. Setting
  `recurse=0` keeps the overlay on `/` only and leaves `/boot` (and any
  other non-root fstab mount) as a direct mount. Verified on a
  `recomputer-rk3588-devkit` image: `/boot` is now mounted directly from
  `armbi_boot` and writes reach the raw partition.

#### Secure boot & secure rootfs

- **Rockchip secure U-Boot bootchain.** New `RK_SECURE_UBOOT_ENABLE=yes`
  profile builds U-Boot with ATF + OP-TEE (BL32), packages the kernel as a
  signed FIT, and flashes a raw boot partition. LUKS root and OP-TEE/SSKR
  automatic unlock are enabled automatically.
- **OP-TEE secure rootfs.** New `RK_OPTEE_BOOT_ENABLE=yes` profile enables
  LUKS root + OP-TEE automatic unlock *without* the full secure U-Boot flow.
  It is mutually exclusive with `RK_SECURE_UBOOT_ENABLE`.
- **Extension-owned secure boot assets** under `rk_secure-disk-encryption/u-boot/`:
  - `fit-generator/make_fit_atf_optee.sh` — ATF + OP-TEE U-Boot FIT generator
  - `fit-kernel/rk3576_fit_kernel.its`, `rk3588_fit_kernel.its` — final kernel
    FIT ITS templates, split per SoC
  - `fragments/rk3576-secure-autodecrypt.config`,
    `rk3588-secure-autodecrypt.config` — secure U-Boot Kconfig fragments
- **Secure A/B FIT OTA.** The A/B backend verifies `boot.itb` and writes it
  directly to the inactive raw `boot_a`/`boot_b` partition. It never mounts a
  FIT boot partition or treats the FIT image as `boot.tar.gz`.
- **Caller-supplied FIT key directory.** Secure boot can sign with a key
  directory provided by the caller, and verifies the embedded SPL FIT key
  material during build.
- **`DEFAULT_OVERLAYS` baked into the FIT DTB.** Raw-FIT images have no
  `/boot` filesystem, so runtime dtbo loading is impossible; the build now
  applies the overlay list to the device tree copy before FIT packaging.
- **Encrypted A/B and Recovery OTA.** Both A/B modes create a shared `security`
  partition and format both rootfs slots as LUKS-backed ext4 when automatic
  decryption is enabled. Encrypted images use the initramfs-unlocked
  `/dev/mapper/armbian-userdata` mapper as the overlayroot backing device.

#### OTA payload security

- **Encrypted and signed OTA payloads.** On encrypted-rootfs images the OTA
  packaging encrypts `rootfs.tar.gz` (AES-256-CBC, key derived from the
  LUKS passphrase via HKDF-SHA256) and signs `payload.manifest` (IV, plaintext
  digest, metadata) with the secure-boot RSA key (RSA-PSS/SHA256). The
  matching public key is installed into the firmware at build time; the device
  verifies the signature, decrypts, and re-checks digests before applying.
  Packages carry `OTA_ENCRYPTED` in `package.env` and the CLI refuses a
  package whose encryption state disagrees with the device.

#### Boot-disk anchoring

- **Pre-filled persistent U-Boot environment in built images.** The final
  environment (compiled defaults merged with the OTA template) is written as
  an env blob at the raw offset `0x3f8000` during image build, with overlap
  checks against the loader and first partition plus a CRC read-back. A/B
  images get the full slot state (`boot_slot`, `boot_success`,
  `ota_in_progress`, `slot_retry_max/left`, `ab_preboot`) and
  `ab_boot_mode=raw-fit` is injected for secure-boot FIT boot.
- **Bootdev-anchored root selection.** The initramfs resolves the root by
  the `armbian.bootdev`/`bootdevnum` cmdline tokens — carried by every
  `bootcmd` branch and exported through `/conf/param.conf` — instead of
  first-match, so with several disks (or a cloned image) attached, root,
  userdata, and key material are only ever taken from the disk U-Boot
  actually booted from.

#### Robustness & tooling

- **SSH power-loss recovery (`ssh-protect`).** Power loss during first boot
  can zero-fill or truncate `/etc/ssh` files, leaving sshd unable to start
  and the board unreachable. Every image now ships a repair script running
  as `ExecStartPre` of `ssh.service`: broken host keys are regenerated, a
  corrupted `sshd_config` is restored atomically from the distro default
  (NUL-byte corruption is detected explicitly — `sshd -t` alone treats it
  as whitespace). No-op on healthy systems.
- **Offline FIT re-signing (`scripts/repack-fit.sh`).** Re-packs an existing
  signed `boot.itb` with a new dtbo list and re-signs it with the same RSA
  key — no Armbian rebuild needed. Includes a sample-FIT builder mode for
  testing the re-sign path and refuses to re-sign the build-time staging
  artifact in place.
- **Image-builder CI workflow (`build-images.yml`, was `seeed-build`).** A matrix image builder on GitHub Actions:
  preflight validates secrets before the multi-hour build (FIT key pair,
  64-char passphrase, live rclone probe), the matrix is planned from dispatch
  checkboxes (board × release × tier × OTA × security; plain and secure-boot
  coexist), images upload to OneDrive pre-release storage with per-run
  cleanup, and an optional single GitHub Release covers all boards with
  per-board IMAGE|OTA tables. Board dkms packages (`maxio-phy`,
  `wq9201s-wifi-bt`, `pcie-rkep`) joined the userspace build matrix.
- **Board support.** `fcs960k-aic-bluez` installed with the common package
  set.

#### OTA

- **New modular OTA layout.** `armbian-ota/` is reorganized into
  `common/`, `recovery/`, and `ab/`, each with a `build-hooks/`
  (build-time) and `rootfs/` (image contents) tree. Files under each
  `rootfs/` mirror their final path in the image and are installed via
  `rsync`.
- **Mode auto-detection.** The unified `armbian-ota` CLI detects OTA mode from
  the package manifest — `--mode=recovery` / `--mode=ab` is no longer required.
- **Encrypted A/B OTA backend** with slot selection by active slot, encrypted
  A/B root slot detection, and shared-security-partition layout.
- **Recovery full-root overlayroot.** Recovery OTA now uses a full-root
  overlayroot with the final `userdata` partition as the writable upper layer,
  plus persistent overlays for `/etc`, `/home`, and `/var/lib`.
- **`armbian-ota switch-slot [a|b]`** for manual slot maintenance after OTA
  has completed (replaces the old manual `rollback`/`mark-success` commands,
  which are now driven automatically by systemd units).
- **A/B rootfs size tiers** and configurable partition sizing: `OTA_BOOT_SIZE`,
  `OTA_USERDATA_SIZE`, `OTA_SECURITY_SIZE`, and optional `OTA_ROOTFS_SIZE`
  (auto-calculated from built rootfs + headroom when unset).
- **Package metadata & versioning.** OTA packages now ship `package.env`
  (mode + metadata, replacing `ota_manifest.*`) and `version.txt`
  (image name, version, build commit, extension commit). An OTA-mode suffix
  is appended to image filenames.
- **First-boot userdata resize** for both modes via `armbian-resize-userdata.service`.
  Encrypted images log that a reboot is required, then reopen the
  `armbian-userdata` LUKS mapper at its new size on the next boot.

#### Build & entry script

- **`scripts/build.sh` profile wrapper.** A single entry point composes build
  profiles (`recovery`, `ab`, `secure-rootfs`, `secure-boot`) with board,
  release, desktop, and tier options, replacing raw `export`-then-`compile.sh`
  invocations.
- **Step-by-step documentation** under `docs/` (getting started, build
  reference with per-variable source links, per-feature OTA/encryption/
  secure-boot guides, tools & CI), with a rewritten top-level `README.md`
  as the quick-entry point.
- **Seeed SDK tools fork.** `rockchip_sdk_tools` defaults to the Seeed fork
  (`github.com/Seeed-Studio/rockchip_sdk_tools.git`), overridable via
  `RKSDK_TOOLS_GIT_URL` / `RKSDK_TOOLS_BRANCH`.
- **Mirror/cache passthrough** through the build wrapper.
- **PCIe ASPM disabled** in generated images via `extraargs=pcie_aspm=off`.

#### CI

- **OneDrive mirror: slot-first layout + per-slot tag files; no more
  build-info.json.** The images tree is re-rooted from
  `images/<board>/<slot>/…` to
  `images/<slot>/<board>/<profile>[-secure-boot]/…` (slot ∈ pre-release /
  latest / previous): rotation unit now equals release unit, promotion is
  one server-side move per slot (every board flips together, no per-board
  parallel rclone), and the staging purge at build start is a single
  call. Each slot carries a `tag` file (the YYMMDD-HHMM build stamp)
  written once every matrix entry has uploaded — it is the page's slot
  binding (slot labels no longer inferred from release-list ordering) and
  promote verifies it names the release being promoted before rotating.
  The release carries no assets: the old `build-info.json` manifest is
  gone (its identity role moved to `<slot>/tag`; releases without assets
  are what promote's cleanup treats as superseded). The page walk lists
  the whole `images/` tree in one `lsjson -R` (boards are discovered, no
  board list input) and reads the three `tag` files; the release-list
  inference stays as the fork-mode fallback (`SLOTS={}`).
- **`apt-repo-publish.yml`: rk3576-module board, family-scoped kernel.**
  New `build_rk3576_module` dispatch input extends the per-board matrix.
  Kernel debs are family-scoped in Armbian (`linux-image`/`-headers`/
  `-dtb` are per LINUXFAMILY and the DTB deb carries every family DTB),
  so the first selected board of each family compiles the kernel once
  and sibling boards build only their board-specific U-Boot — no
  duplicate same-named kernel debs in the publish merge, no extra
  kernel CI time per added board.
- **`apt-repo-publish.yml`: rk3576-industrial board.** New
  `build_rk3576_industrial` dispatch input (default on). Each matrix job
  checks the board config exists in the selected `armbian_build_ref` and
  skips gracefully with a notice when it does not — the board is not in
  `Seeed-Studio/armbian-build` main yet, so default runs skip it until
  the branch lands (meanwhile dispatch with
  `armbian_build_ref=rk3576-industrial`).
- **`apt-repo-publish.yml`: kernel compilation now opt-in.** New
  `build_kernel` dispatch input (default false): the official Armbian
  apt already hosts the `vendor-seeed-rk3576`/`rk3588` family kernels,
  so the matrix builds U-Boot only by default; enable the input to
  rebuild and publish family kernels (hotfix channel — the version
  must outrank the official one to reach devices).
- **`apt-repo-publish.yml`: kernel and U-Boot build in parallel.** The
  board matrix carries a `target` dimension (`uboot` per selected board,
  `kernel` per family when `build_kernel` is on), so each entry is an
  independent job — a board's U-Boot no longer serializes behind its
  kernel compile. Artifact names carry the target
  (`debs-uboot-<board>`, `debs-kernel-<board>`).

### Changed

- **Dual-payload assertion shared by both OTA modes.** The KIND=full
  assertion (both the rootfs archive and a boot member must exist AND be
  covered by their checksum files -- a broken build that drops e.g. boot.tar
  together with boot.sha256 would otherwise still verify green and apply
  "new rootfs + old boot") moved from `recovery_assert_dual_tar` to
  `ota_assert_dual_payload` in `common.sh`; `ab_start_ota` now runs it too
  (A/B previously had no equivalent check).
- **BOARD/RELEASE gate now covers both OTA modes, with an explicit
  cross-release escape hatch.** The board/release matching that Recovery
  enforced inside `recovery_check_package_metadata` moved into the shared
  `ota_check_board_release` pre-flight (`armbian-ota start`'s `check_ota_pkg`
  step), so A/B packages are now checked too (previously A/B accepted any
  board/release silently). Packages missing `BOARD`/`RELEASE` in `package.env`
  are refused outright instead of silently passing. Cross-release updates
  (e.g. trixie <-> resolute) remain blocked by default but can be accepted
  explicitly with the new `armbian-ota start --allow-release-change` (both
  modes; BOARD mismatch is never overridable).
- **Stock image naming; OTA packages under `ota/`.** Recovery images no
  longer carry a `_RECOVERY` suffix (stock names, no router changes); A/B
  keeps its `_AB_PART` marker. OTA packages are layout-agnostic
  (`..._OTA.tar.gz`, mode recorded in `package.env`) and are now written to
  `output/images/<BOARD>/ota/` instead of the images root, so each board's
  packages land under its own subfolder on the mirrors
  (`dl.armbian.com/BOARD/ota/FILE`).
- **Boot-size precedence unified across OTA layouts**: `OTA_BOOT_SIZE` now
  wins over `BOOTSIZE` everywhere (recovery previously preferred `BOOTSIZE`,
  secure boot ignored it).
- **Leaner default OTA partition sizing**: rootfs headroom 30% → 20%,
  userdata 1024 → 512 MiB, boot 512 → 256 MiB. A 6.1 GiB desktop rootfs
  now yields a ~8.1 GiB recovery image instead of ~9.3 GiB. Overrides:
  `OTA_BOOT_SIZE` / `OTA_ROOTFS_SIZE` / `OTA_USERDATA_SIZE`.
- **`rk-uboot-postprocess` hooks are now opt-in via `RK_COMPILE_USBPLUG=yes`.**
  They were enabled unconditionally, which broke Armbian CI (2026-09-19): with
  no usbplug compiled, the RK3588 path referenced `rk35/rk3588_usbplug_v1.11.bin`
  — never shipped in armbian/rkbin — and `boot_merger` aborted with exit 245 on
  every image build. Plain builds now use the upstream postprocess paths and
  ship no Maskrom loader in the u-boot deb; Maskrom builds (already setting
  `RK_COMPILE_USBPLUG=yes`) are unaffected.

- **FIT signing switched to the Rockchip rkbin prebuilt `mkimage`.** The
  board-side verifier only accepts maximum-salt RSA-PSS signatures, while
  the in-tree `mkimage` links against the build container's OpenSSL and
  OpenSSL ≥ 3.5 defaults PSS to digest-length salt — producing signatures
  that verify at build time and fail on the board. The prebuilt static
  binary pins the max-salt behavior; the resolver requires a signing-capable
  `mkimage` (the per-SoC rkbin builds differ — the RK3588 one silently emits
  unsigned FITs — so any signing-capable prebuilt serves both platforms) and
  the result is overridable via `RK_SECURE_BOOT_MKIMAGE`. The tree-built
  `fit_check_sign` remains the build-time verifier so any future salt drift
  fails the build instead of the boot. Applies to secure-boot image/U-Boot
  signing and to `repack-fit.sh`.
- **Default boot partition size raised to 512 MiB** — both the OTA layout
  default and the secure-boot raw FIT boot partition.
- **Extension-carried patch bundles dropped** once armbian-build merged the
  content upstream (firstlogin SSH restart, RK3576 Panfrost / RK3588 Panthor
  GPU stacks, remaining U-Boot/armbian-build patches); board defconfigs stay
  in the Armbian build tree.
- **OTA entry script slimmed down.** `ota-support.sh` is now a thin Armbian
  hook entry point (was a ~1130-line monolith); implementation moved into
  `armbian-ota/{common,recovery,ab}/build-hooks/`.
- **Secure boot / auto-decrypt hooks modularized.** `rk-secure-boot.sh` and
  `rk-auto-decryption-disk.sh` are now Armbian hook wrappers that load
  implementation from `rk_secure-disk-encryption/build-hooks/{common,
  auto-decryption,secure-boot-uboot,secure-boot-image}.sh`.
- **U-Boot environment handling.** Non-secure A/B images store boot state at
  the fixed raw U-Boot env offset (`0x3f8000`, `0x8000`) via distro `fw_*env`
  tools. Filesystem A/B packages U-Boot's complete compiled default
  environment and merges A/B variables into `/etc/u-boot-initial-env`, so
  first-boot `fw_setenv -f` does not discard commands like `distro_bootcmd`.
- **Persistent data model.** User account DB files (`passwd`, `shadow`,
  `group`, `gshadow`, `subuid`, `subgid`) remain normal overlay files (needed
  for `useradd`/`groupadd` atomic rewrite). Runtime writes to `/home` and
  `/var/lib` persist on `armbi_usrdata` via overlayroot.
- **Recovery payload location** moved to `userdata/ota-recovery/ota_work/`;
  the initramfs rewrites only the raw rootfs lower layer and leaves userdata
  intact.
- **Board U-Boot defconfigs** are maintained in the Armbian build tree
  (`patch/u-boot/legacy/u-boot-radxa-rk35xx/defconfig/`), keeping bootloader
  changes in the normal Armbian U-Boot patch flow.

### Removed

- **`firstlogin-protection/` extension dropped** (upstreamed). The hardened
  firstlogin logic and its atomic-write / hardening patches are removed; the
  SSH-restart behavior moved upstream.
- **Offline `ota_tools/` bundle** removed from OTA packages — the OTA runtime
  is now installed into the firmware at image build time.
- **Old OTA directory structure** removed: `runtime/` (monolithic CLI +
  backends), `recovery_ota/` (incl. `fit/fit-ota`, `99-ota-apply`),
  `ab_ota/`, and the standalone `armbian-resize-userdata` unit — all replaced
  by the new `common/` + `recovery/` + `ab/` layout.
- **Dead/redundant OTA helpers** cleaned up (userdata persist helper, NVMe
  bootscript env import, OTA verbosity hooks, manual `rollback` CLI).
- **Old auto-decrypt assets** removed (`auto-decrypt-disk.sh` standalone,
  `rk-cryptroot-verbosity.sh`, board defconfigs that lived in-repo).

### Fixed

- **A/B payload extraction died on compressed tarballs (`tar: Archive is
  compressed. Use -J option`).** `ab_extract_tar_payload` piped the raw
  payload through `pv` straight into `tar -xf -`; GNU tar only auto-detects
  compression on seekable archive files, so reading compressed bytes from a
  pipe aborts (observed on rk3576, tar 1.35, encrypted `rootfs.tar.xz` —
  decrypt and verify had already succeeded). The no-`pv` fallback was
  equally broken, hardcoding `-xzf` (gzip-only). Both paths now run an
  explicit `<decompressor> | tar -xf -` pipeline with the codec picked by
  payload suffix (xz/zst/gz, mirroring the recovery initramfs `payload.sh`),
  with `xz -T0` matching the build-side parallel compression.

- **Encrypted-package phase-1 regression and bidirectional encryption
  gate.** The format-negotiation refactor (`16e43ad8`) made
  `ota_resolve_payload_names()` require a plaintext `rootfs.tar.<fmt>` to
  exist, but encrypted packages intentionally ship only
  `rootfs.tar.<fmt>.enc` (plaintext deleted on the build side), so
  `armbian-ota start` on an encrypted system aborted with "No rootfs
  payload" before the decrypt step could ever run. The resolver now counts
  the encrypted blob too (the resolved name is the decryption target).
  On top of that fix, payload/system encryption must now match in both
  directions before verify/decrypt: an encrypted package is refused on a
  plain system (it cannot derive the payload key), and a plaintext package
  is refused on an encrypted system — the plain rootfs carries no unlock
  hook, so the update would apply "successfully" and leave the device
  unbootable. The check cross-validates `package.env`'s `OTA_ENCRYPTED`
  against the staged payload, and the recovery initramfs re-checks the
  pair (`.enc` presence vs `AUTO_DECRYPT_MODE`) as a phase-2 backstop.

- **Multi-disk boot anchoring.** With several disks attached (or a cloned
  image as a second device), every lookup now binds to the disk U-Boot
  actually booted from, so foreign or cloned disks can no longer capture
  root selection, updates, or key material. Follow-ups to the original
  batch: the init-top anchor install hook wrote to `${MOUNT}` during the
  rootfs stage (where it is an empty staging dir), so no built image ever
  carried the anchor or the `pcie_aspm=off` extraargs — both now install
  into `${SDCARD}`; the overlay upper layer follows the anchored `$ROOT`
  instead of re-parsing `root=` from the cmdline through udev's
  duplicate-UUID symlinks; `/boot` is mounted by `zz-seeed-mount-boot` from
  the same-disk anchor recorded in `/run` (the earlier `/dev/armbian-boot`
  fstab scheme stalled systemd: hand-made /dev symlinks never satisfy
  udev-backed device units):
  - A/B boot and rootfs selection anchored to U-Boot's actual boot disk;
    userdata anchored to the boot disk across initramfs and runtime.
  - Recovery userdata lookup anchored to the rootfs disk; recovery
    initramfs writes and security-partition key lookup anchored to the boot
    disk; the device-encryption probe anchored likewise, and the recovery
    probe answers from the running root filesystem (a LUKS volume on an
    attached second disk no longer answers for the boot device).
  - LUKS `PARTLABEL` lookups iterate all candidates and stay anchored to the
    root disk, so a plain image on a second disk can no longer make the
    userdata unlock silently fail and drop runtime state onto the lower
    layer (the "OTA reflashed my device" data-loss class).
- **Raw-FIT A/B first boot without the distro scan.** Initial images without
  `ab_boot_mode` fell into `distro_bootcmd`, where each scanned device ran
  `boot_android` and repointed the FIT boot device pointer (observed as
  `No boot partition` on RK3588 SD boot). The scan hooks no longer call
  `boot_android`, the dead `bootrkp` tail is gone, and `raw-fit` is
  pre-filled at build time.
- **init-top ROOT export.** initramfs-tools runs init-top scripts as child
  processes, so inline `ROOT=` assignments never propagated; the anchored
  root is now exported through `/conf/param.conf`.
- **`armbian-ota switch-slot`** previously reported success while U-Boot
  kept booting the old slot; the slot switch now persists.
- **User device-tree overlays are preserved** in `armbianEnv.txt` across OTA
  updates, and `armbianEnv.txt.dist` is kept in sync on both OTA paths.
- **Recovery OTA debug/verbosity settings** (printk level, xtrace) no longer
  leak into normal boots.
- `fix(build)`: keep the cryptroot passphrase out of `argv` (pass via env/stdin
  instead of command line).
- `fix(autodecrypt)`: apply the defconfig fragment *after* patching; retain
  SPL FIT key material; restore FIT signing tools after USBPLUG build.
- `fix(ota)`: mark filesystem A fallback bootable; preserve the complete
  U-Boot environment; fail hard on A/B update / runtime-state / preserve-copy
  errors; detect and select encrypted A/B root slots by active slot.
- `fix(ota)`: defer encrypted userdata resize until reboot; resize encrypted
  userdata without prompting.
- `fix(recovery)`: use BusyBox-compatible `tar` extraction in the initramfs.
- `fix(secure-boot)`: isolate the U-Boot package name; verify the embedded SPL
  FIT key; sign the final secure boot FIT directly.
- `fix(u-boot)`: RK3576 `fdt-fixup` NULL-bootdev fallback staged for boards
  that boot without a bootdev token.
- `build`: close a stale cryptroot mapper before image build.

## [1.0.0] — 2026-04-14

Initial import of the Seeed Armbian extension: OTA updates (Recovery + A/B),
LUKS disk encryption with OP-TEE auto-decrypt, firstlogin hardening, and
security hardening.

[Unreleased]: https://github.com/Seeed-Studio/seeed_armbian_extension/compare/v1.0...main
[1.0.0]: https://github.com/Seeed-Studio/seeed_armbian_extension/releases/tag/v1.0
