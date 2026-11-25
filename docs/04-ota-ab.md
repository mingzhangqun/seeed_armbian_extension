# 4. A/B OTA (Dual Slot, Automatic Rollback)

A/B firmware keeps **two complete systems** (boot + rootfs each). Updates are
written to the inactive slot while the device keeps running; on reboot the
bootloader switches to the new slot, and if it does not come up healthy the
system rolls back automatically. This is the failsafe option — a bad update
cannot brick the device.

1. [Build the firmware](#1-build-the-firmware)
2. [Partition layout](#2-partition-layout)
3. [Apply an update on the device](#3-apply-an-update-on-the-device)
4. [How rollback works (two layers)](#4-how-rollback-works-two-layers)
5. [Slot maintenance](#5-slot-maintenance)
6. [U-Boot environment reference](#6-uboot-environment-reference)
7. [Troubleshooting](#7-troubleshooting)

## 1. Build the firmware

```bash
./build.sh ab -b recomputer-rk3576-devkit
```

Encrypted + signed variant:

```bash
CRYPTROOT_PASSPHRASE='<64-char-passphrase>' \
./build.sh ab secure-boot -b recomputer-rk3576-devkit
```

Update packages are built the same way as for Recovery — every build emits
`*_AB_PART_OTA.tar.xz` under `output/images/<BOARD>/ota/`.

## 2. Partition layout

Created by [`ab/build-hooks/partitions.sh`](../armbian-ota/ab/build-hooks/partitions.sh):

```text
plain:       [ boot_a ext4 ][ boot_b ext4 ][ rootfs_a ext4 ][ rootfs_b ext4 ][ userdata ext4 ]
encrypted:   [ boot_a ][ boot_b ][ security 4M ][ rootfs_a LUKS+ext4 ][ rootfs_b LUKS+ext4 ][ userdata LUKS+ext4 ]
```

| PARTLABEL | fs label | Role |
|---|---|---|
| `boot_a` / `boot_b` | `armbi_boota` / `armbi_bootb` | one boot partition per slot (raw FIT partitions under secure boot) |
| `security` | — | shared key material (encrypted images) |
| `rootfs_a` / `rootfs_b` | `armbi_roota` / `armbi_rootb` | one rootfs per slot |
| `userdata` | `armbi_usrdata` | shared: overlay upper layer, user data, both slots' runtime state |

Notes:

- Boot is **two partitions** (not shared); `security` and `userdata` are shared.
- Runtime writes land on the shared `userdata` overlay
  ([`overlayroot.sh`](../armbian-ota/common/build-hooks/overlayroot.sh)) —
  slot switches and updates never touch it.
- Each slot's boot partition defaults to
  [`OTA_BOOT_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L31)
  (512 MiB) — an A/B image needs roughly twice the plain Recovery space.
- The persistent U-Boot environment is stored at raw offset `0x3f8000`
  with a redundant copy at `0x3f0000` (size `0x8000` each, unconditional
  on every shipped board) on the boot disk, pre-filled at build time by
  [`uboot-env-prefill.sh`](../armbian-ota/common/build-hooks/uboot-env-prefill.sh)
  so a fresh image boots with working slot logic before Linux ever runs.

## 3. Apply an update on the device

**On device:**

```bash
armbian-ota start /path/to/Armbian_..._AB_PART_..._OTA.tar.xz
reboot
```

The backend ([`ab/backend.sh`](../armbian-ota/ab/rootfs/usr/share/armbian-ota/ab/backend.sh))
then, still on the **old** system:

1. Verifies the package (checksums; on encrypted images: signature when
   present — secure-boot builds only — AES decryption, digest re-check;
   `OTA_MODE=ab` and encryption state must match). Staging uses the existing
   userdata overlay upper at `/media/root-rw/ota-ab/`; the backend never
   unlocks or mounts that live filesystem a second time.
2. Writes the full payload to the **inactive** slot — rootfs is extracted
   into the inactive root partition (LUKS opened with the same passphrase,
   header untouched), `boot.tar.gz` onto the inactive boot partition or the
   verified `boot.itb` dd-written to the raw inactive boot partition.
3. Patches the target slot's `armbianEnv.txt`/fstab/crypttab; your device-tree
   overlays in `armbianEnv.txt` are preserved across the update.
4. Sets `ota_in_progress=1`, `boot_slot=<new slot>`, resets the retry budget,
   and asks for a reboot.

After the reboot the new slot runs through the health check; on success the
slot is marked good. `armbian-ota status` shows slot + OTA state at any time.

> **Loader constraint:** OTA never reflashes the SPI loader. It assumes the
> device loader comes from the same image generation (redundant-env layout,
> FIT trust); a device flashed with an older or different-key loader must
> reflash via maskrom first, which also upgrades the loader.

## 4. How rollback works (two layers)

**Layer 1 — systemd** (needs a booting userspace):
[`armbian-ota-firstboot.service`](../armbian-ota/ab/rootfs/etc/systemd/system/armbian-ota-firstboot.service)
runs
[`armbian-ota-health-check`](../armbian-ota/ab/rootfs/usr/lib/armbian/armbian-ota-health-check)
on the first boot of a pending slot — correct slot active, kernel
version readable, virtual filesystems mounted, root writable. Pass →
`mark-success` (`boot_success=<slot>`, `ota_in_progress=0`); fail → the
unit's `OnFailure=` restores the previous slot and reboots.

**Layer 2 — U-Boot** (works even when userspace never starts):
`ab_preboot` decrements `slot_retry_left` on every boot of a pending
slot; when the budget (default 3, set by `slot_retry_max`) is exhausted,
U-Boot itself resets `boot_slot` to `boot_success`. On the resulting old-slot
boot, `armbian-ota-firstboot.service` runs `armbian-ota reconcile`, records
`STATUS=rollback`, clears the target slot, and leaves the confirmed slot
running. If U-Boot is no longer pending but the state cannot be proven to be a
completed rollback, it records `failed` rather than falsely claiming success.

Full lifecycle diagram:
[`armbian-ota/README.md`](../armbian-ota/README.md#how-ota-works).

## 5. Slot maintenance

**On device:**

```bash
armbian-ota status            # current slot, OTA state
armbian-ota switch-slot       # switch to the other slot (reboot to apply)
armbian-ota switch-slot a     # ... or explicitly to slot a / b
reboot
```

`switch-slot` refuses to run while a boot trial is in progress. It starts a
new pending trial: `boot_slot` changes, `boot_success` stays on the confirmed
slot, `ota_in_progress=1`, and the retry budget resets. Reboot manually to
apply; the first-boot health check then confirms the target, or failure/retry
exhaustion rolls back to the previous slot. The `mark-success`/`rollback`
subcommands are internal to the first-boot units.

## 6. U-Boot environment reference

State variables (see [`ab/rootfs/etc/u-boot-initial-env`](../armbian-ota/ab/rootfs/etc/u-boot-initial-env)):

| Variable | Meaning |
|---|---|
| `boot_slot` | slot to boot next reset (`a`/`b`) |
| `boot_success` | last slot that passed health checks |
| `ota_in_progress` | 1 while an update or manual slot switch is pending verification |
| `slot_retry_max` / `slot_retry_left` | boot-attempt budget for the pending slot (default 3) |
| `ab_boot_mode` | `filesystem` or `raw-fit` boot path; plain never falls back to FIT |
| `ab_boot_devtype` / `ab_boot_devnum` | boot device anchoring |
| `distro_bootpart_a` / `distro_bootpart_b` | boot partition number per slot |
| `ab_preboot` | pre-boot script: retry bookkeeping + hard rollback |

```bash
# inspect / override by hand (know what you are doing)
fw_printenv -n boot_slot
fw_setenv boot_slot a
```

## 7. Troubleshooting

**On device:**

```bash
armbian-ota status
cat /var/log/armbian-ota/ota.log     # start-time + health check log
fw_printenv                          # full slot state
```

| Symptom | Meaning / action |
|---|---|
| Device keeps reverting to the old slot | New slot failed health checks or did not boot 3× — read `ota.log` from the old slot |
| `OTA package encryption mismatch` | Package tier ≠ device tier |
| `switch-slot` refuses | A boot trial is pending (`ota_in_progress=1`) — let it finish or roll back first |
| After manual `fw_setenv` experiments | Ensure `boot_slot` ≠ garbage and `slot_retry_left` ≥ 1 |

Developer internals: [`armbian-ota/README.md`](../armbian-ota/README.md).
