# Changelog

All notable changes to the Seeed Armbian board support extensions are
documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — secure boot, OTA overhaul, boot-disk anchoring, CI

Covers the work against the initial import (merge base `9980aee`,
2026-07-02 → 2026-09-15).

### Added

#### Recovery OTA

- **Dedicated `/boot` partition for all Recovery images.** Plain and
  auto-decrypt Recovery builds now reserve a separate ext4 boot partition
  (label `armbi_boot`) and mount it via fstab on top of overlayfs. This
  fixes runtime writes to `/boot` (apt kernel upgrades, `armbianEnv.txt`
  edits, OTA tooling) being swallowed by the overlayfs upper layer on
  userdata and silently ignored by U-Boot on next boot. Secure-boot
  Recovery continues to use a raw FIT boot partition (`BOOT_RAW_MODE=yes`),
  unchanged. The partition order is now `[boot][security?][rootfs][userdata]`.
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
- **`seeed-build` CI workflow.** A matrix image builder on GitHub Actions:
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

- **`build-and-publish.yml`: rk3576-module board, family-scoped kernel.**
  New `build_rk3576_module` dispatch input extends the per-board matrix.
  Kernel debs are family-scoped in Armbian (`linux-image`/`-headers`/
  `-dtb` are per LINUXFAMILY and the DTB deb carries every family DTB),
  so the first selected board of each family compiles the kernel once
  and sibling boards build only their board-specific U-Boot — no
  duplicate same-named kernel debs in the publish merge, no extra
  kernel CI time per added board.
- **`build-and-publish.yml`: rk3576-industrial board.** New
  `build_rk3576_industrial` dispatch input (default on). Each matrix job
  checks the board config exists in the selected `armbian_build_ref` and
  skips gracefully with a notice when it does not — the board is not in
  `Seeed-Studio/armbian-build` main yet, so default runs skip it until
  the branch lands (meanwhile dispatch with
  `armbian_build_ref=rk3576-industrial`).
- **`build-and-publish.yml`: kernel compilation now opt-in.** New
  `build_kernel` dispatch input (default false): the official Armbian
  apt already hosts the `vendor-seeed-rk3576`/`rk3588` family kernels,
  so the matrix builds U-Boot only by default; enable the input to
  rebuild and publish family kernels (hotfix channel — the version
  must outrank the official one to reach devices).
- **`build-and-publish.yml`: kernel and U-Boot build in parallel.** The
  board matrix carries a `target` dimension (`uboot` per selected board,
  `kernel` per family when `build_kernel` is on), so each entry is an
  independent job — a board's U-Boot no longer serializes behind its
  kernel compile. Artifact names carry the target
  (`debs-uboot-<board>`, `debs-kernel-<board>`).

### Changed

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

- **Multi-disk boot anchoring.** With several disks attached (or a cloned
  image as a second device), every lookup now binds to the disk U-Boot
  actually booted from, so foreign or cloned disks can no longer capture
  root selection, updates, or key material:
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
