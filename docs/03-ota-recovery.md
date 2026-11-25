# 3. Recovery OTA (Single System)

Recovery OTA updates a single-system device: the new rootfs is staged on the
`userdata` partition and applied by the initramfs on the next reboot. Simple,
disk-efficient — one rootfs partition — but the update window is not
rollback-protected (unlike [A/B OTA](04-ota-ab.md)).

1. [Build the firmware](#1-build-the-firmware)
2. [Partition layout you are creating](#2-partition-layout-you-are-creating)
3. [Build the update package](#3-build-the-update-package)
4. [Apply an update on the device](#4-apply-an-update-on-the-device)
5. [What happens during the update reboot](#5-what-happens-during-the-update-reboot)
6. [Encrypted images](#6-encrypted-images)
7. [Troubleshooting](#7-troubleshooting)

## 1. Build the firmware

```bash
./build.sh recovery -b recomputer-rk3576-devkit
```

Flash the resulting image; the OTA runtime is preinstalled. From now on,
updates are just packages — no reflash.

## 2. Partition layout you are creating

Created by [`recovery/build-hooks/partitions.sh`](../armbian-ota/recovery/build-hooks/partitions.sh), located by GPT labels:

```text
plain:         [ boot ext4 ][ rootfs ext4 ][ userdata ext4 ]
auto-decrypt:  [ boot ext4 ][ security 4M ][ rootfs LUKS+ext4 ][ userdata LUKS+ext4 ]
secure boot:   [ boot raw FIT ][ recovery raw FIT ][ security 4M ][ rootfs LUKS+ext4 ][ userdata LUKS+ext4 ]
```

Plain Recovery boots only through ext4 `/boot` and `/recovery/`, with no raw
FIT fallback. Secure/raw-FIT Recovery boots the signed FIT from the raw `boot`
or `recovery` partition.

| PARTLABEL | fs label | Role |
|---|---|---|
| `boot` | `armbi_boot` | `/boot`, mounted directly (never overlayed) — or raw FIT under secure boot |
| `recovery` | — | raw-FIT layouts (secure-boot): raw FIT rescue partition (same boot.itb as boot, flashed at build time, booted by the U-Boot `boot_fit` command; never touched by OTA) |
| `security` | — | key material (encrypted images only) |
| `rootfs` | `armbi_root` | read-only rootfs lower layer |
| `userdata` | `armbi_usrdata` | overlay upper layer + OTA transaction store; auto-expands on first boot |

Sizes: [`OTA_BOOT_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L31)
(default 512 MiB), `OTA_ROOTFS_SIZE` (computed +20% headroom),
[`OTA_USERDATA_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L36)
(default 512 MiB — a build-time floor, expanded to the full disk on first
boot) — see [Build Reference](02-build-reference.md).

### Why updates keep your data

`/` is an overlay mount ([`overlayroot.sh`](../armbian-ota/common/build-hooks/overlayroot.sh),
`recurse=0`):

```text
/       lower: rootfs partition    read-only   replaced wholesale by an update
        upper: userdata partition  writable    apt packages, /home, /var/lib
/boot   direct mount               not overlaid  kernel/armbianEnv.txt visible to U-Boot
```

An update rewrites only the root and boot partitions; the writable upper
layer is never touched, so everything installed or saved survives. On the
first boot [`armbian-resize-userdata`](../armbian-ota/common/rootfs/usr/lib/armbian/armbian-resize-userdata)
grows the userdata partition to fill the disk (encrypted images resize
the LUKS mapping and the filesystem online in the same boot).

## 3. Build the update package

Any later build with the same profile **also** emits an OTA package next to
the image:

```text
output/images/<BOARD>/ota/Armbian_*_OTA.tar.*
```

Stock image names — no `_RECOVERY` suffix; the OTA mode is recorded in
`package.env`.

Contents (assembled by [`package-create.sh`](../armbian-ota/common/build-hooks/package-create.sh)):

| File | Required | Notes |
|---|---|---|
| `rootfs.tar.gz` + `rootfs.sha256` | yes | new rootfs |
| `boot.tar.gz` + `boot.sha256` | ext4 boot | new `/boot` contents |
| `boot.itb` | secure boot | signed FIT, written raw — mutually exclusive with `boot.tar.gz` |
| `package.env` | yes | `OTA_MODE`, `OTA_ENCRYPTED`, board/release/branch/version/kernel metadata |
| `version.txt` | yes | image name, build commit, extension commit |
| `rootfs.tar.gz.enc`, `payload.manifest`, `payload.manifest.sig` | encrypted images | see [below](#6-encrypted-images) |

Next to the package the build also writes `<image>_OTA.checksums`
(MD5 + SHA256 of the tarball) for distribution-side integrity checks.

Transfer the package to the device any way you like — scp, USB stick,
download:

```bash
scp output/images/<BOARD>/ota/Armbian_*_OTA.tar.* root@<device>:/root/
```

## 4. Apply an update on the device

**On device:**

```bash
armbian-ota start /path/to/Armbian_..._OTA.tar.zst
reboot
```

`armbian-ota start` ([source](../armbian-ota/common/rootfs/usr/sbin/armbian-ota)):

- takes one package argument; optional `--force` reinstalls the same payload,
  `--no-backup` skips creating a last-good backup, and
  `--allow-release-change` explicitly permits a cross-release update. The mode
  is auto-detected from `package.env` and must match the firmware
  (`OTA_MODE=recovery`),
- refuses a package whose encryption state differs from the device
  (`OTA_ENCRYPTED` vs. actual),
- verifies checksums and, on Secure Boot builds, requires a valid manifest
  signature; secure-rootfs retains its unsigned-manifest compatibility path
  with a warning (see [06-secure-boot.md](06-secure-boot.md)),
- stages the payload under `userdata/ota-recovery/payloads/` and marks the
  state `prepared`.

Then reboot. The initramfs does the rest — see next section.

> **Loader constraint:** OTA never reflashes the SPI loader. It assumes the
> device loader comes from the same image generation (redundant-env layout,
> FIT trust); a device flashed with an older or different-key loader must
> reflash via maskrom first, which also upgrades the loader.

After the update reboot:

```bash
armbian-ota status     # STATUS=success
```

## 5. What happens during the update reboot

The initramfs hook
([`scripts/init-premount/99-ota-apply`](../armbian-ota/recovery/initramfs/scripts/init-premount/99-ota-apply))
runs before the real root is mounted. It anchors every device lookup to
the disk U-Boot actually booted from (`armbian.bootdev` cmdline tokens —
a cloned disk can never capture the update), validates the staged
payload, then applies the new rootfs and boot contents in one verified
pass, patches `armbianEnv.txt`/fstab/crypttab for the new UUIDs, marks the
state `applied`, and reboots once into the normal role. The health service
then verifies the running candidate and promotes its verified payload to
last-good, changing `STATUS=success`; it then clears the U-Boot transaction
flag directly. If the system reboots into Rescue before that flag is cleared,
Rescue completes the reconciliation.

**Failure behavior:** Rescue retries a failed candidate up to three times.
After the attempts are exhausted it fully verifies the last-good backup,
switches to a restore campaign, and boots that backup for health confirmation.
With no usable backup, or if restore also fails, it stays in the Rescue shell
rather than booting a partially written rootfs. This is not the immediate
A/B-style rollback; see [A/B OTA](04-ota-ab.md) for inactive-slot recovery.

Lifecycle diagram and step-by-step internals:
[`armbian-ota/README.md`](../armbian-ota/README.md#how-ota-works).

## 6. Encrypted images

On encrypted builds the update flow is identical from the user's perspective,
but:

- the package carries `rootfs.tar.<fmt>.enc` instead of plaintext; the device
  verifies the manifest signature when present (and always requires one on
  Secure Boot builds) before decrypting, then re-checks digests — key
  derivation and verification in
  [`common.sh`](../armbian-ota/common/rootfs/usr/share/armbian-ota/common.sh);
- the initramfs applies the payload through `/dev/mapper/armbian-root`;
- the same passphrase/keys unlock everything — see
  [05-encryption.md](05-encryption.md).

## 7. Troubleshooting

**On device:**

```bash
armbian-ota status                    # state machine position
cat /var/log/armbian-ota/ota.log      # start-time verification/staging log
cat /run/initramfs/ota.log            # initramfs apply log (after reboot)
ls /dev/disk/by-partlabel/            # verify partitions are on the boot disk
```

| Symptom | Meaning |
|---|---|
| `OTA package encryption mismatch` | Package tier ≠ device tier — flash matching firmware or rebuild the package |
| `STATUS=prepared` persists after reboot | Initramfs apply keeps failing — read `/run/initramfs/ota.log` |
| Partition not found | It must live on the U-Boot boot disk (multi-disk anchoring) |

Developer internals (hook ordering, runtime file layout):
[`armbian-ota/README.md`](../armbian-ota/README.md).
