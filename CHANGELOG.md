# Changelog

Notable changes to the Seeed Armbian board support extensions. Categories
follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); nodes are
date + commit anchors, newest first.

## [Unreleased]

m-dev integration line since 1.2.0: OTA infrastructure themes (recovery-infra
/ metadata-gates / plain-gate / ci-infra) and the redundancy-cleanup series.

### Fixed

- **CI passes `GITHUB_TOKEN` to the image build.** The aic8800
  latest-release lookup ran unauthenticated (60 req/hour per runner IP,
  403 on shared IPs) and killed builds after a full kernel compile; the
  asset-API fallback now reuses the same token instead of the never-wired
  `AIC8800_GITHUB_TOKEN`.
- **README passphrase claim was stale.** "Validated non-empty only"
  predates the secure-storage hard gate: the build fails any passphrase
  whose length is not exactly 64; the hex charset stays documentation-only.
- **Redundant env everywhere; no single-copy fallback.** Every shipped
  U-Boot carries the redundant-env patch, so the probe/per-SoC gating and
  `env-sanitize-single.bin` are gone: `fw_env.config` is always two
  entries, the prefill always writes the `-r` dual copy. The old probe
  guessed single-copy when no copy parsed; a both-bad rebuild then wrote
  a blob the patched U-Boot could never read (default-env Rescue loop).
- **One env-health predicate and rebuild mechanism on both flavors.**
  The bad-CRC retry is `fw_setenv -f /etc/u-boot-initial-env` (the
  libubootenv defenv base), same as A/B's `ab_env_initialize_default`;
  the dd-sanitize machinery is deleted, `ab/env.sh` sources the common
  `fwenv.sh`, and `armbian-ota-init-uboot` runs every boot so a mid-life
  both-bad env self-heals on A/B too. The health check must read stderr:
  `fw_printenv` exits 0 on a bad env once the initial env exists.
- **`start` holds the OTA lock through the package metadata read.** The CLI
  read `package.env` (seconds on a large tar) before any lock, so a
  concurrent `switch-slot` could legally take the lock mid-read and arm a
  boot trial while the start was still running — two writers with no
  arbitration. The lock is now acquired at CLI entry and is re-entrant
  with the backend's own `acquire_lock`.
- **A/B plain self-heals a stale target-root mount before mkfs.** A
  SIGKILLed start leaves the inactive target root mounted in its OTA work
  dir; the next start died at mkfs ("is mounted") and OTA stayed wedged
  until manual umount or reboot. Plain A/B now mirrors the secure side's
  stale-mapper self-heal: residue mounts are detached before rebuilding,
  with a bounded wait for an orphaned extract pipeline to finish.
- **Loader/OS mismatch fails fast at decryption.** A secure image booted
  under a plain loader (no BL32/OP-TEE) previously fell through to a
  manual cryptroot password prompt that could never succeed;
  decryption-disk now panics with an explicit loader/OS-mismatch message
  so first boot halts cleanly instead of appearing to wait for a
  passphrase.
- **Secure FIT packaging survives a debs-cache hit.** With the kernel
  deb restored from cache (kernel never compiled), the worktree has no
  built DTB and no `resource.img`, so all secure-boot builds died at
  "Board DTB not found" (exit 43) — or would have shipped an empty
  `resource.img`. The board DTB now falls back to the rootfs
  `/boot/dtb` tree (linux-dtb deb) and `resource.img` is rebuilt at
  image time from the resolved DTB.
- **Boot-swap hook swaps the payload marker.** `bsw_classify` left
  `payload-id` at `skip`, so every hook-mode OTA failed health check 6
  and rolled back its own successful apply; it now flips last
  (`critical`), after all boot files.
- **Preserved `recovery/` counts toward boot capacity.** The rescue-asset
  measurement ran after the boot partition was unmounted (condition
  always false); it now runs while mounted.
- **Passphrase length is enforced at build time.** Initramfs reads a
  fixed 64 bytes; a non-64-char `CRYPTROOT_PASSPHRASE` (only CI
  preflight checked) unlocked with NUL padding and bricked first boot.
  Write-verification mismatch is now a hard error too.
- **Missing `root_dir` hard-fails the OP-TEE initramfs install** instead
  of shipping an image that dies at the TEE gate.
- **FIT signing prep runs in the parent shell.** The `$(...)` capture
  forked away `RK_SECURE_BOOT_MKIMAGE` and let the `make tools-only` log
  pollute `fit_padding`; full secure builds failed at U-Boot FIT signing.
  Padding now travels in `RK_SECURE_BOOT_FIT_PADDING`.
- **fwenv temp files use `mktemp`** instead of predictable `/tmp` paths
  written by root.
- **Security-part scan anchor accepts `sdX`/`vdX` partitions** (`p?[0-9]+`);
  those disks previously fell back to the unanchored first PARTLABEL hit.

- **A/B init survives a missing boot-mode stamp.** Sourcing fwenv.sh ran the
  on-device layout probe at load time; on A/B images the stamp never exists
  (Recovery-only producer), so the failed `cat` aborted set -e callers at
  the source line — fw_env.config generation and every A/B OTA start died.
  The read is now failure-tolerant.
- **Library load guards propagate.** env.sh/ota_source_library/CLI no longer
  swallow a missing-fwenv `return 1`; the A/B CLI exits cleanly instead of
  failing later on undefined functions.
- **Release gate falls back to `/etc/armbian-release`** on images without
  the identity stamp: the cross-release gate is no longer silently skipped
  on legacy devices.
- **Mirror reconcile sweeps only owned repos and reports honestly.** Kernel
  source tags are deleted only when the fork belongs to the pipeline's
  owner (stale-draft GC and the retire step); a 204 DELETE response is no
  longer decoded as an error; stale-draft GC runs on every reconcile exit
  path; dangling-candidate cleanup also sweeps extension/kernel source tags.

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
- **Standard CLI image handling.** `--minimal` selects `BUILD_DESKTOP=no`
  without enabling Armbian's separate minimal-rootfs policy. The download page
  recognizes the resulting suffixless CLI image names as well as encrypted and
  A/B variants.
- **APT publication to owner-root Pages.** The APT repository publishes at
  `https://<owner>.github.io/` with independent Pages concurrency, and the
  generated package index classifies boards by U-Boot package prefix instead
  of dropping new boards into "Other".
- **AIC8800 release downloads.** CI caches validated debs, retries downloads
  and falls back to GitHub's asset API when release URLs fail; invalid cached
  packages are discarded. Upstream extension errors during this best-effort
  download path do not abort the image build.
- **OP-TEE toolchain selection with ccache.** Auto-decrypt builds bypass
  compiler-only ccache wrapper directories when locating the complete AArch64
  and Arm32 toolchain binaries needed by the TA build.

### Security

- **Plan outputs are charset-validated.** A newline in a dispatch repo input
  could inject or override other `GITHUB_OUTPUT` keys (matrix, tag) and
  steer the build matrix.

### Added

- **Unconditional redundant U-Boot env.** Every board ships the second copy
  at 0x3f0000: `-r` prefill and the two-entry `fw_env.config` always; torn
  writes leave one copy intact, both-bad rebuilds via
  `fw_setenv -f /etc/u-boot-initial-env -s`.
- **Trixie libubootenv CRC self-heal.** `fw_env_crc_bad` matches the trixie
  wording and flags a CRC-valid-but-empty blob; the `-f` rebuild runs on
  full-set routing writes only, partial writes fail with the blob untouched.
- **Encrypted userdata resizes in one boot.** `cryptsetup resize` grows the
  LUKS mapping online using the initramfs-stashed key; the
  resize-then-reboot flow is gone.
- **Verified-build `booti` lockdown.** Raw Image execution is refused on
  `FIT_SIGNATURE` builds (C-level guard; `DISTRO_DEFAULTS` selects it on
  ARM64, so Kconfig cannot disable it).

### Changed

- **README leads with the official Armbian board pages.** The not-yet-live
  images page and its releases are no longer advertised; the Documentation
  index lists one entry per line.
- **A/B env repair key spec is single-sourced.** The missing/sync key lists
  live in `ab/env-keys.sh`; the runtime repair loop and the build-time
  initial-env completeness check both source it, so a spec drift fails the
  build instead of `ab_env_repair_defaults` on every boot.
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
- **secure-disk-encryption redundancy cleanup.** FIT-signing prep deduped
  into one helper; dead knobs and debug scaffolding removed.

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

