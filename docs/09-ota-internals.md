# 9. OTA Internals: Flow, Payloads, State Machines

Developer reference for what actually happens between `armbian-ota start` and
the reboot log. This is the interface baseline for the [package-format and
apply-hook contracts](10-ota-package-formats.md). User-facing workflows live in
[Recovery OTA](03-ota-recovery.md) and [A/B OTA](04-ota-ab.md).

1. [Command journey](#1-command-journey)
2. [Phase 1: package detection and prepare](#2-phase-1-package-detection-and-prepare)
3. [Payload extraction matrix](#3-payload-extraction-matrix)
4. [State machines](#4-state-machines)
5. [Runtime file map](#5-runtime-file-map)

## 1. Command journey

```
armbian-ota start <pkg>
  └─ CLI (usr/sbin/armbian-ota)
      ├─ ① check_ota_pkg            GNU tar auto-detects the outer compression
      ├─ ② dispatch by OTA_MODE     whichever backend.sh the firmware ships
      ├─ ③ phase-1 prepare          recovery: stage + verify, wait for reboot
      │                             ab:       stage + verify + flash target slot
      └─ ④ apply                    recovery: initramfs 99-ota-apply after reboot
                                  ab:       firstboot service dual gate
```

## 2. Phase 1: package detection and prepare

Common entry (`check_ota_pkg` in `usr/sbin/armbian-ota`):

| Step | Action | Tools | Failure behavior |
|---|---|---|---|
| 1 | root + argument sanity (rejects `-` options) | — | exit 1 |
| 2 | package file exists | — | `OTA package not found` |
| 3 | list members, locate `package.env`, read it | `tar -tf` (auto-detects compression) | `metadata missing` |
| 4 | validate `OTA_MODE ∈ {ab, recovery}`, `OTA_ENCRYPTED ∈ {yes, no}` | — | explicit error |
| 5 | device-side encryption probe; must equal package declaration. Recovery probes the fs this system runs from; AB probes GPT PARTLABELs anchored to the U-Boot boot disk | `findmnt`/`df`/`blkid` | mismatch aborts |
| 6 | BOARD/RELEASE match vs `/etc/armbian-release` (`ota_check_board_release`, shared by both modes; missing package fields abort; RELEASE escapable via `--allow-release-change`) | `sed` | mismatch aborts |
| 7 | dispatch to `<mode>_start_ota` (absent backend = unsupported firmware) | — | `backend not installed` |

Recovery prepare (`recovery_start_ota`, runs in the live system):

| # | Action | Tools | Notes |
|---|---|---|---|
| 1 | re-assert package mode | `tar -xOf` | |
| 2 | transaction store mounted (`/media/root-rw`) | `mountpoint` | userdata overlay backing |
| 3 | `extract_ota_package` → `ota_resolve_payload_names` | `tar -xf` | stages into `<userdata>/ota-recovery/ota_work`; resolver binds `OTA_PAYLOAD_ROOTFS_TAR`/`BOOT_TAR` to the files present (`.tar.xz` preferred over `.tar.gz`) |
| 4 | `ota_verify_payload`: sha256 per archive; encrypted packages verify + decrypt `*.enc` first | `sha256sum`, `openssl` | |
| 5 | `state_mark_prepared recovery prepared` | — | state file on userdata |
| 6 | print reboot hint | — | phase 2 owns everything after |

AB prepare (`ab_start_ota`, runs in the live system, **flashes the target slot
immediately**):

| # | Action | Tools |
|---|---|---|
| 1 | environment check: U-Boot env sane, `rootfs_a/b` + `boot_a/b` PARTLABELs exist, current slot from kernel cmdline | `fw_printenv`, `blkid` |
| 2 | `extract_ota_package` + `ota_verify_payload` (shared with recovery) | `tar`, `sha256sum`, `openssl` |
| 3 | `ab_update_target_partition`: unlock target if LUKS (key from security partition flow) → mount → `empty_mount_dir` clean (**no mkfs**; UUID/label preserved) → extract rootfs payload → write target boot (tar extract or `boot.itb` dd) → rewrite target `fstab`/`armbianEnv.txt` UUIDs → sync + unmount | `cryptsetup`, `mount`, `tar`, `dd` |
| 4 | `state ready_to_boot` + `ab_env_prepare` (switch `boot_slot`, set `ota_in_progress=1`) | `fw_setenv` |

Key structural difference: recovery rewrites the rootfs partition from the
initramfs (mkfs + extract, idempotent retries), AB writes the inactive slot
from the live system (clean + extract, old slot untouched until success).

## 3. Payload extraction matrix

Where each archive is unpacked, by mode and phase:

| Mode | Phase | Environment | Unpacks | Tools (source) | Command shape | Target |
|---|---|---|---|---|---|---|
| recovery | P1 | live system | outer package | GNU tar (system) | `tar -xf pkg -C ota_work` | userdata staging |
| recovery | P2 | initramfs | `rootfs.tar.xz`/`.tar.gz` | GNU tar + xz/gzip (**real binaries staged by the 99-copy-tools hook**) | `tar -xJf` / `-xzf` | freshly mkfs'd rootfs partition |
| recovery | P2 | initramfs | `boot.tar.xz`/`.tar.gz` | same | same | boot partition |
| recovery | P2 | initramfs | `boot.itb` | `dd` | `dd bs=4M conv=fsync` | raw boot partition (FIT) |
| ab | P1 | live system | outer package | GNU tar | `tar -xf` | `/ota_work/ab-package.XXXXXX` |
| ab | P1 | live system | rootfs payload → target slot | `pv` + GNU tar | `pv file \| tar --xattrs --acls --numeric-owner -xf - -C root_mnt` | cleaned target root partition |
| ab | P1 | live system | boot payload → target slot | tar / dd | same / `dd` | target boot partition |
| any (encrypted) | P1 | live system | `rootfs.*.enc` → plaintext tar | `openssl aes-256-cbc` + `sha256sum` re-check | decrypt then normal verification | staging dir |

## 4. State machines

State files:

| Mode | File | Readers | Writers |
|---|---|---|---|
| recovery | `<userdata>/ota-recovery/state/ota-state.env` | initramfs 99-ota-apply, CLI status | phase-1 backend, initramfs commit |
| ab | `/var/lib/armbian-ota/ota-state.env` | CLI, firstboot/rollback services | phase-1 backend, mark-success |
| ab | U-Boot env: `boot_slot`, `ota_in_progress` | U-Boot, firstboot | `fw_setenv` |

Recovery:

| STATUS | Entered when | Next trigger | Failure semantics |
|---|---|---|---|
| `idle` | `state_init` | `armbian-ota start` | — |
| `prepared` | phase 1 verified | user reboots → initramfs applies (`OTA_MODE=recovery` ∧ `STATUS=prepared` ∧ payload present) | any phase-2 failure unmounts and exits 0 with state **left at `prepared`** → next boot retries automatically (idempotent: mkfs rebuild makes retries clean) |
| `success` | phase 2 complete (payload staging dir deleted) | — | — |

AB (three focal points: state file + U-Boot env + the actually-booted slot):

| STATUS | Entered when | U-Boot env | Next |
|---|---|---|---|
| `idle` | initial | `ota_in_progress=0` | `start` |
| `ready_to_boot` | target slot flashed | `boot_slot=target`, `ota_in_progress=1` | reboot into new slot |
| `success` | firstboot service passes the **dual gate** (`STATUS ∈ {ready_to_boot, boot_verifying}` ∧ `ota_in_progress=1`) | `ota_in_progress` cleared | normal operation |
| failure | new slot unhealthy | `ota_in_progress` still 1 | rollback service / CLI switches back; the old slot was never touched |

The dual gate exists so a crash that leaves `ready_to_boot` but U-Boot unset
cannot false-mark success on a non-target boot.

## 5. Runtime file map

| Path | Role |
|---|---|
| `usr/sbin/armbian-ota` | CLI: argument parsing, package checks, mode dispatch |
| `usr/share/armbian-ota/common.sh` | shared helpers: metadata read, extraction, payload-name resolution, sha256, encrypted-payload handling |
| `usr/share/armbian-ota/state.sh` | state file read/write primitives |
| `usr/share/armbian-ota/{recovery,ab}/backend.sh` | mode-specific phase 1 |
| `usr/share/armbian-ota/ab/{env,target}.sh` | slot/env helpers, target-slot flash |
| `etc/initramfs-tools/scripts/init-premount/99-ota-apply` | recovery phase-2 orchestrator |
| `etc/initramfs-tools/ota/recovery/{device,log,payload}.sh` | initramfs libs (busybox-sh) |
| `etc/initramfs-tools/hooks/99-copy-tools` | stages real tar/gzip/xz (+libs) and OTA libs into the initramfs |
