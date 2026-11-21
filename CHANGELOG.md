# Changelog

Notable changes to the Seeed Armbian board support extensions. Categories
follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); nodes are
date + commit anchors, newest first.

## [Unreleased]

m-dev integration line since 1.2.0: OTA infrastructure themes (recovery-infra
/ metadata-gates / plain-gate / ci-infra) and the redundancy-cleanup series.

### Fixed

- **Security-partition discovery now anchors to the boot disk.** `lsblk -no
  PKNAME` emits bare kernel names (no `/dev/` prefix) and rejects bare names
  as inputs, so the disk filter never matched and every pick fell through to
  the unanchored first match (both `ota_get_security_part` and the A/B copy).
  Multi-disk clones could read the wrong disk's key partition.
- **Target-slot A/B state file gets real values.** `ota_state_commit_tmp` /
  `ota_state_set_key` wrote to the global state file regardless of the file
  argument, so `ab_write_target_state` populated the RUNNING system's state
  and left the target slot an empty template. State writes also collapse to
  one atomic write per transaction boundary.
- **Plain U-Boot carries no live raw-FIT entry.** The default-env patch
  `#else`, the build prefill and the runtime routing set write `*_boot_fit`
  as refusal stubs on plain (keys kept for CRC-rebuild compat); plain A/B
  prefill stamps `ab_boot_mode=filesystem`. A loader/OS mismatch on plain
  stops at env routing, not the initramfs TEE gate.
- **A/B rollback and switch reconciliation.** U-Boot retry exhaustion records
  `STATUS=rollback`; an unconfirmed pending state records `failed`, never
  `success`. Manual `switch-slot` starts a pending boot trial with the same
  health confirmation as OTA.

### Added

- **Redundant U-Boot env on rk3576/rk3588.** Staged U-Boot patch enables
  `CONFIG_ENV_OFFSET_REDUND` (0x3f0000): a saveenv power cut leaves the other
  copy intact, both-bad falls back to the compiled default env (Rescue).
  Redundancy is probed per device before the second `fw_env.config` entry, so
  booters without the patch stay single-copy. The both-bad rebuild sanitizes
  to a build-generated rescue blob — never a valid-CRC empty env, which hangs
  autoboot.
- **Trixie libubootenv CRC self-heal.** `fw_env_crc_bad` matches the trixie
  wording; `fw_setenv` refusing a bad-CRC env triggers sanitize-and-retry on
  full-set writes only. Partial writes fail with the blob untouched.
- **Encrypted userdata resizes in one boot.** `cryptsetup resize` grows the
  LUKS mapping online using the initramfs-stashed key; the
  resize-then-reboot flow is gone.
- **Verified-build `booti` lockdown.** Raw Image execution is refused on
  `FIT_SIGNATURE` builds (C-level guard; `DISTRO_DEFAULTS` selects it on
  ARM64, so Kconfig cannot disable it).

### Changed

- **U-Boot routing env has a single source of truth.** The routing scripts
  live only in fwenv.sh; the build prefill sources it, and the default-env
  patch's rescue keys are machine-verified against the compiled default env
  at every recovery build. Disk/parent-disk resolution likewise converged
  into fwenv.sh/find-userdata.sh (was seven hand-rolled copies).
- **`ota_assert_dual_payload` runs on the extracted staging dir** — no
  second full package stream; space and capacity gates still fail first.
- **Image identity stamps consolidated.** `RELEASE` / `IMAGE_VARIANT` /
  `SEEED_*` land in `/etc/armbian-image-release`; the release gate compares
  build-stamped truth (unstamped images skip with a warning). zstd
  capability is probed, not declared — A/B images install zstd for parity.
- **secure-disk-encryption redundancy cleanup.** FIT-signing toolchain prep
  (prebuilt mkimage + USBPLUG tool rebuild + RSA4096 padding) is one helper
  shared by the U-Boot FIT and boot FIT paths (was two ~40-line copies).
  `get_luks_device_by_partlabel` drops a second pass that was identical to
  the first when no anchor disk is set. Dead weight removed: the
  `SECURE_STORAGE_SECURITY_FS_TYPE` mkfs knob (never set, security partition
  stays raw), the unreachable `BOOTSIZE=256` fallback in the RAW-boot
  capture hook, fstab debug scaffolding (full-file cat dumps, `.bak`), and
  `rk_secure_boot_minimize_spl_fit_key` is renamed to
  `rk_secure_boot_verify_spl_fit_key_complete` to match what it does.

## 2026-11-13 ([f76cd2d3](https://github.com/Seeed-Studio/seeed_armbian_extension/commit/f76cd2d3))

The hardening wave: Recovery OTA v0.8 redesign, the OTA gate matrix,
multi-disk boot anchoring, and the CI image pipeline. 106 commits since
1.1.0.

### Added

- **Recovery OTA v0.8: independent Rescue + campaign lifecycle.** The same
  initramfs boots normal or Rescue (`armbian.ota_role`); Rescue reconciles
  state + env after any power cut, then drives
  prepared → applied → reboot → health-confirm with a retry budget and
  automatic restore of the lazy last-good backup on exhaustion. The
  transaction store lives on userdata; power loss is safe at every point.
  The hardware watchdog is disarmed for the Rescue stay.
- **fwenv library: verified U-Boot env writes.** Readback-verified sets,
  explicit bad-CRC detection and rebuild of the full routing set, plus the
  `seeed-ota-rescue-default-env` U-Boot patch (fail-safe compiled default
  env routes to Rescue, never arbitrary media).
- **Secure-boot Rescue: dedicated `PARTLABEL=recovery` partition** holding
  the same signed boot.itb, flashed at build time and booted via the vendor
  `boot_fit` command — signature verification applies to rescue too.
- **Payload format negotiation.** xz / zst / gz with magic-byte sniffing and
  a single format map; `OTA_PAYLOAD_COMP` + `--ota-format` override; pigz
  parallel gzip; parallel xz decode on device.
- **Package-provided OTA hooks** (pre/apply/post/firstboot contract) and the
  atomic per-file boot-swap hook (`OTA_BOOT_REFRESH=0`).
- **Production loaders.** `spl_loader_maskrom.bin` in every u-boot deb,
  exported to `<board>/<plain|secure>/loaders/` (xz + sha256); SPI loader
  image for boards that build one.
- **CI image pipeline.** Matrix image builder with secret preflight; OneDrive
  immutable tag-tree mirror with pointer/`slots.json` promotion; static
  download page fed by one `data.json`; `apt-repo-publish` (family-scoped
  kernel, per-board U-Boot jobs); OCR review workflow with severity gates.
- **Real tools in the recovery initramfs** (GNU tar/gzip/xz/dd/sha256sum,
  mke2fs) over busybox applets.

### Fixed

- **Multi-disk boot anchoring.** Root, userdata, /boot and key material are
  bound to the disk U-Boot actually booted from (`armbian.bootdev` cmdline
  tokens) — a cloned or foreign second disk can no longer capture boot
  selection, updates or secrets. `/boot` mounts from the initramfs (fstab
  device units never satisfied udev-backed units and stalled boot ~90 s).
- **A/B payload extraction on compressed tarballs.** GNU tar does not
  auto-detect compression on pipes; both extract paths now run an explicit
  `<decompressor> | tar -xf -` pipeline with exit propagation.
- **Encrypted-package phase-1 regression + bidirectional encryption gate.**
  The resolver counts `rootfs.tar.<fmt>.enc`; payload/system encryption must
  match in both directions before verify/decrypt (a plain package on an
  encrypted system applies "successfully" and bricks the boot).
- **PR #37 hardening batch.** Staging estimates cover compressed/encrypted
  members; raw-FIT writes verify the full extent; the last-good backup is
  revalidated before promotion; secure boot requires signed OTA manifests;
  the mirror rejects malformed history and shell-unsafe tags; preflight
  enforces RSA-2048.
- **A/B lifecycle correctness.** Retry limit enforced after power-cut
  re-entry; U-Boot rollback state reconciled from the firstboot service;
  stale LUKS mappers self-heal before unlocking the target slot.

### Changed

- **Gate matrix before any side effect.** Capacity gates compare
  `ROOTFS_BYTES`/`BOOT_BYTES` stamps against target partitions (110% ext4
  margin, raw FIT 1:1) before recovery's mkfs destroys the old rootfs; A/B
  staging moved off the live rootfs onto userdata with a space gate;
  BOARD/RELEASE/variant gates are shared by both modes with
  `--allow-release-change` as the explicit cross-release hatch; the
  KIND=full dual-payload assertion is shared (A/B previously had none).
- **Dedicated ext4 `/boot` partition for all recovery images** +
  `recurse=0` on overlayroot: runtime writes to /boot (kernel upgrades,
  armbianEnv edits) reach the raw partition instead of being swallowed by
  the overlay upper.
- **Rootfs mkfs fast path** (fs label + UUID replay) replaces the
  rm -rf clean; rootfs headroom raised to 50% for future payload growth.
- **Loader/OS mismatch enforcement.** Secure U-Boot fragments Kconfig-disable
  `bootz/source/pxe/boot_android/go`; Kconfig fragments are verified after
  `olddefconfig` so a hidden `select` fails the build instead of silently
  re-enabling.

## 2026-09-21 ([bfb8fce2](https://github.com/Seeed-Studio/seeed_armbian_extension/commit/bfb8fce2))

The modular framework era: extension split into per-domain trees, secure
boot profiles, and the build wrapper. 221 commits since 1.0.0.

### Added

- **Secure boot profiles.** `RK_SECURE_UBOOT_ENABLE` (ATF + OP-TEE U-Boot
  FIT, signed kernel FIT, raw boot partition) and `RK_OPTEE_BOOT_ENABLE`
  (LUKS root + OP-TEE auto-unlock without the signed bootchain); mutually
  exclusive, both auto-enable encryption + auto-decrypt. Extension-owned
  fit generator, per-SoC kernel ITS templates and Kconfig fragments.
- **Encrypted A/B and Recovery OTA** with a shared `security` partition and
  LUKS-backed rootfs slots; encrypted and signed OTA payloads
  (AES-256-CBC, HKDF from the LUKS passphrase, RSA-PSS manifest signature).
- **`scripts/build.sh` profile wrapper** (recovery / ab / secure-rootfs /
  secure-boot × board / release / desktop / tier) and the `docs/` guide
  suite.
- **SSH power-loss recovery (`ssh-protect`)**: regenerates broken host
  keys and restores a corrupted `sshd_config` at ssh.service start.
- **Offline FIT re-signing (`scripts/repack-fit.sh`).**

### Changed

- **Modular OTA layout.** `armbian-ota/{common,recovery,ab}` with
  build-hooks + rootfs trees; `ota-support.sh` is a thin entry (was a
  ~1130-line monolith). Mode auto-detection from `package.env`;
  `switch-slot` replaces manual rollback/mark-success; `package.env` +
  `version.txt` replace `ota_manifest.*`; partition size knobs
  (`OTA_BOOT/ROOTFS/USERDATA/SECURITY_SIZE`); first-boot userdata resize.
- **Stock image naming; OTA packages under `<board>/ota/`.** Recovery
  images drop the `_RECOVERY` suffix; packages are layout-agnostic.
- **FIT signing via the Rockchip rkbin prebuilt `mkimage`** — pins the
  max-salt RSA-PSS behavior the board verifier requires.
- **`rk-uboot-postprocess` hooks opt-in** (`RK_COMPILE_USBPLUG=yes`):
  unconditionally-enabled hooks broke Armbian CI (missing usbplug binary,
  exit 245).
- **Board U-Boot defconfigs** moved to the Armbian build tree;
  extension-carried patch bundles dropped once upstreamed
  (firstlogin, GPU stacks).

## 2026-04-14 ([e5819e63](https://github.com/Seeed-Studio/seeed_armbian_extension/commit/e5819e63))

Initial import of the Seeed Armbian extension: OTA updates (Recovery + A/B),
LUKS disk encryption with OP-TEE auto-decrypt, firstlogin hardening, and
security hardening.

