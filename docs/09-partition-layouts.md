# 9. Partition Layouts (Plain Recovery / Plain A/B / Secure Recovery / Secure A/B)

One page that shows the **on-disk layout** produced by each OTA profile —
the raw areas below the GPT, the GPT partitions themselves, and how
`boot.itb` and the persistent U-Boot environment fit into the picture.

Diagram: [`diagrams/partition-layouts.svg`](diagrams/partition-layouts.svg)
(PNG: [`diagrams/partition-layouts@2x.png`](diagrams/partition-layouts@2x.png))

1. [The four profiles at a glance](#1-the-four-profiles-at-a-glance)
2. [The fixed boot-media region (below the GPT)](#2-the-fixed-boot-media-region-below-the-gpt)
3. [The GPT partition layouts](#3-the-gpt-partition-layouts)
4. [boot.itb vs. u-boot.itb — two FITs, similar names](#4-bootitb-vs-u-bootitb--two-fits-similar-names)
5. [What the U-Boot environment actually carries](#5-what-the-u-boot-environment-actually-carries)
6. [Trust boundaries across the four profiles](#6-trust-boundaries-across-the-four-profiles)

## 1. The four profiles at a glance

| Profile | Build command | Partitions | `/boot` form | rootfs | userdata | ENV contents |
|---|---|---|---|---|---|---|
| ① Plain Recovery | `./build.sh recovery` | 3 | ext4 fileset | ext4 | ext4 | bootcmd + bootdev token |
| ② Plain A/B | `./build.sh ab` | 5 | ext4 fileset ×2 | ext4 ×2 | ext4 | full A/B slot state |
| ③ Auto-Decrypt Secure Recovery | `./build.sh recovery secure-boot` | 4 | raw `boot.itb` | LUKS+ext4 | LUKS+ext4 | bootcmd + bootdev token |
| ④ Auto-Decrypt Secure A/B | `./build.sh ab secure-boot` | 6 | raw `boot.itb` ×2 | LUKS+ext4 ×2 | LUKS+ext4 | full A/B slot state |

Source of truth:
[`recovery/build-hooks/partitions.sh`](../armbian-ota/recovery/build-hooks/partitions.sh),
[`ab/build-hooks/partitions.sh`](../armbian-ota/ab/build-hooks/partitions.sh),
[`common/build-hooks/partitions.sh`](../armbian-ota/common/build-hooks/partitions.sh).

## 2. The fixed boot-media region (below the GPT)

Identical on every profile. Addressed by **sector**, not by partition — the
GPT table does not describe these areas.

| Sector | Byte offset | Size | Blob | Signed? |
|---|---|---|---|---|
| 0 | `0x0` | 32 KiB | protective MBR / GPT | — |
| 64 | `0x8000` | ~4 MiB | `idbloader.img` (TPL + SPL) | secure-boot only |
| 8128 | **`0x3f8000`** | **32 KiB** | **U-Boot environment** | CRC32 only (never signed) |
| 16384 | `0x800000` | ~8 MiB | `u-boot.itb` (ATF + OP-TEE + U-Boot) | secure-boot only |

The environment area is **pre-filled at build time** by
[`common/build-hooks/uboot-env-prefill.sh`](../armbian-ota/common/build-hooks/uboot-env-prefill.sh)
via `mkenvimage`, so the very first boot already runs the token-carrying
`bootcmd` (and, on A/B, the full slot state machine) without waiting for
`armbian-ota-init-uboot.service` to populate it.

A layout assertion at
[`uboot-env-prefill.sh:98`](../armbian-ota/common/build-hooks/uboot-env-prefill.sh#L98)
verifies the env area never overlaps the loader blob above it or partition 1
below it — the build fails if a future loader grows past `0x3f8000`.

## 3. The GPT partition layouts

The GPT itself sits at `OFFSET` (16 MiB by default; Armbian
`IMAGE_PARTITION_TABLE=gpt`, `table-length=64`). Partition numbers below
match what U-Boot and Linux see as `p1`, `p2`, … on the boot disk.

### ① Plain Recovery — 3 partitions

```text
[ p1 boot ext4 | p2 rootfs ext4 | p3 userdata ext4 ]
```

- `p1` carries the kernel fileset: `Image`, `uInitrd`, `dtb/`,
  `armbianEnv.txt`, `extlinux/`. It is mounted directly at `/boot`
  (bypassing overlayroot) so runtime edits are visible to U-Boot on the
  next boot.
- `p2` is the read-only overlay lower layer; OTA replaces it wholesale.
- `p3` is the overlay upper layer plus the OTA transaction store
  (`ota-recovery/ota_work/`, `ota-recovery/state/ota-state.env`).

### ② Plain A/B — 5 partitions

```text
[ p1 boot_a ext4 | p2 boot_b ext4 | p3 rootfs_a ext4 | p4 rootfs_b ext4 | p5 userdata ext4 ]
```

- Two complete boot partitions, one per slot. `boot_a` carries the
  `LegacyBIOSBootable` GPT attribute so U-Boot's distro scan has a
  deterministic fallback when the persistent env is absent or invalid.
- Two complete rootfs partitions; OTA writes the inactive slot while the
  active slot keeps running.
- `userdata` is shared across slots — overlay upper layer, `/home`,
  `/var/lib`, both slots' runtime state.

### ③ Auto-Decrypt Secure Recovery — 4 partitions

```text
[ p1 boot raw FIT | p2 security raw | p3 rootfs LUKS+ext4 | p4 userdata LUKS+ext4 ]
```

- **`p1` has no filesystem.** It is a raw partition whose entire contents
  are a single RSA-PSS-signed `boot.itb` (kernel FIT). The build hook
  [`rk_secure_boot_flash_fit_kernel`](../rk_secure-disk-encryption/build-hooks/secure-boot-image.sh#L521)
  `dd`s it to `${LOOP}p1` after the filesystems are unmounted.
- U-Boot loads it with `boot_fit`, which reads raw blocks and verifies
  the signature against the public key baked into the SPL dtb.
- There is no `/boot` directory at runtime — overlays are baked into the
  FIT's dtb at build time by `fdtoverlay` (see
  [`secure-boot-image.sh:48`](../rk_secure-disk-encryption/build-hooks/secure-boot-image.sh#L48)).
- New `p2 security` (4 MiB raw) holds the OP-TEE keybox; the LUKS
  passphrase is fetched from there once during initramfs and stashed at
  `/run/armbian-luks-passphrase`.
- `p3` and `p4` are LUKS-encrypted with the same passphrase.

### ④ Auto-Decrypt Secure A/B — 6 partitions

```text
[ p1 boot_a raw FIT | p2 boot_b raw FIT | p3 security raw |
  p4 rootfs_a LUKS+ext4 | p5 rootfs_b LUKS+ext4 | p6 userdata LUKS+ext4 ]
```

- `boot_a` and `boot_b` are **independent raw FIT partitions**, one signed
  `boot.itb` per slot. The OTA backend writes the new slot's `boot.itb` to
  the inactive partition and only then flips `boot_slot`.
- `security` and `userdata` are **shared across slots** — slot switches
  never touch key material or user data.
- The `LegacyBIOSBootable` GPT attribute is **not** set on `boot_a` in
  raw-FIT mode (only set in the plain-filesystem A/B variant); U-Boot
  picks the slot from `boot_fit_part` instead of the legacy distro scan.

## 4. boot.itb vs. u-boot.itb — two FITs, similar names

They are **different FIT images**, produced by different tools, at
different stages of the boot chain:

| | `u-boot.itb` | `boot.itb` |
|---|---|---|
| What it packs | ATF BL31 + OP-TEE BL32 + U-Boot proper | kernel + dtb + initrd (+ baked overlays) |
| Lives at | sector 16384 (raw, below GPT) | inside `p1` (③) or `p1`/`p2` (④) raw partition |
| Generated by | U-Boot build (`make u-boot.itb`) | `mkimage -f boot-final.its -k keys/ -E -p <pad> -r` |
| Signed by | Rockchip `rk_sign_tool` chain | RSA-PSS via Rockchip prebuilt `mkimage` (max-salt) |
| Verified by | SPL (pubkey baked into its dtb) | U-Boot (same pubkey chain) |
| Build hook | `secure-boot-uboot.sh` | `secure-boot-image.sh` |

The naming collision is upstream — `boot.itb` is just the conventional
name for "the kernel FIT the bootloader loads." On plain profiles (①②)
there is **no `boot.itb` at all**; the kernel is loaded as loose files
from ext4.

## 5. What the U-Boot environment actually carries

Pre-filled by `uboot-env-prefill.sh` at build time, then maintained by:

- **`fw_setenv`** (Linux userspace — uses `/etc/fw_env.config` written by
  `armbian-ota-init-uboot`)
- **`saveenv`** (U-Boot shell)
- **`ab_preboot`** retry logic (rewrites on every boot of a pending slot)

### Recovery profiles (①③)

```
bootcmd=setenv bootargs "${bootargs} armbian.bootdev=${devtype} \
        armbian.bootdevnum=${devnum}"; <compiled default bootcmd>
```

The single addition over U-Boot's compiled default is the
**`armbian.bootdev` / `armbian.bootdevnum` token** — it anchors every
initramfs partition lookup to the disk U-Boot actually loaded the OS
from, so a cloned disk attached as `/dev/sdb` cannot capture the update.

### A/B profiles (②④)

Adds the full slot state machine on top:

```
boot_slot=a              boot_success=a         ota_in_progress=0
slot_retry_max=3         slot_retry_left=3      ab_boot_mode=filesystem|raw-fit
ab_preboot=…retry decrement + hard rollback…
ab_select_fit_slot=…maps slot → boot_fit_part…     (raw-fit only)
bootcmd=run ab_preboot; …; if raw-fit: run ab_select_fit_slot; boot_fit
                              else: run distro_bootcmd; boot_fit
```

- Plain A/B (②) runs with `ab_boot_mode=filesystem`: U-Boot picks the
  slot's ext4 boot partition via `distro_bootpart_a/b` and reads the
  kernel fileset from it.
- Secure A/B (④) has `ab_boot_mode=raw-fit` injected by
  [`uboot-env-prefill.sh:54-66`](../armbian-ota/common/build-hooks/uboot-env-prefill.sh#L54)
  because the fallback `distro_bootcmd` path breaks `boot_fit` device
  selection on boards with SPI flash — without the injection the first
  boot would never reach Linux.

## 6. Trust boundaries across the four profiles

```text
① plain recovery                ──── everything plaintext, env CRC-only, no signing
                                  ▼
② plain A/B                     ──── same crypto posture, dual slot + rollback
                                  ▼
③ auto-decrypt secure recovery  ──── loaders + kernel FIT signed, /boot abolished,
                                     LUKS rootfs+userdata
                                  ▼
④ auto-decrypt secure A/B       ──── same, plus slot state machine in env for
                                     OTA rollback
```

What changes from ② to ④ (or ① to ③) is **not** the partition count for
the OTA mode — it's whether `/boot` is a filesystem the running system
can modify, and whether the bootchain is signed end-to-end. What changes
from ③ to ④ is whether a failed update can roll back.

## See also

- [`03-ota-recovery.md`](03-ota-recovery.md) — Recovery OTA user flow
- [`04-ota-ab.md`](04-ota-ab.md) — A/B OTA user flow and rollback layers
- [`06-secure-boot.md`](06-secure-boot.md) — signing chain and key management
- [`armbian-ota/README.md`](../armbian-ota/README.md) — developer internals
