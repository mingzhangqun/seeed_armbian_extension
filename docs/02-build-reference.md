# 2. Build Reference

Everything `scripts/build.sh` understands, and every environment variable the
extension reads. Each entry links to the source that consumes it.

1. [Command line](#1-command-line)
2. [Profiles](#2-profiles)
3. [Options](#3-options)
4. [Conflict rules](#4-conflict-rules)
5. [Environment variables](#5-environment-variables)
6. [Caches and rebuild cost](#6-caches-and-rebuild-cost)

## 1. Command line

```
./build.sh [profile...] [options...]
```

The wrapper must be staged next to `compile.sh` in the Armbian build tree
(checked at [`build.sh:353`](../scripts/build.sh#L353)). It exports the
profile flags, unsets HTTP proxies, manages caches, and finally invokes
`./compile.sh` inside Docker. `-n` prints the invocation without building.

Defaults ([`build.sh:7-31`](../scripts/build.sh#L7)): board
`recomputer-rk3576-devkit`, branch `vendor`, release `bookworm`, desktop on
(gnome/mid), `ENABLE_SEEED_RK_EXTENSION=yes`, `RK_COMPILE_USBPLUG=yes`.
Everything can be overridden from the environment.

## 2. Profiles

Profiles are positional words; they compose, except where marked mutually
exclusive. Resolution lives in [`build.sh:123-176`](../scripts/build.sh#L123).

| Profile | Sets | Meaning |
|---|---|---|
| `recovery` | `OTA_ENABLE=yes AB_PART_OTA=no` | Recovery OTA firmware |
| `ab` | `OTA_ENABLE=yes AB_PART_OTA=yes` | A/B OTA firmware — mutually exclusive with `recovery` |
| `secure-rootfs` | `CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes RK_OPTEE_BOOT_ENABLE=yes` | Encryption + automatic unlock, unsigned bootchain — mutually exclusive with `secure-boot` |
| `secure-boot` | `CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes RK_SECURE_UBOOT_ENABLE=yes` | Encryption + signed Rockchip bootchain |

Typical combinations: `recovery`, `ab`, `recovery secure-boot`, `ab secure-boot`,
`secure-rootfs`.

## 3. Options

Parsed in [`build.sh:231-302`](../scripts/build.sh#L231).

| Option | Effect |
|---|---|
| `-b, --board <name>` | Board, e.g. `recomputer-rk3576-devkit`, `recomputer-rk3588-devkit`, `recomputer-rk3576-module-devkit` |
| `-R, --release <name>` | Distribution release (default `bookworm`) |
| `-d, --desktop <env>` | Desktop environment choice (e.g. `gnome`) — takes a value |
| `-t, --tier <tier>` | Desktop tier choice — takes a value |
| `-c, --clear-kernel-cache` | Clear kernel deb/worktree cache before building |
| `-r, --clear-rootfs-cache` | Clear rootfs cache before building |
| `-n, --dry-run` | Print the `compile.sh` invocation, build nothing |
| `--kernel` | Rebuild kernel only (ignores profiles) |
| `--uboot` | Rebuild U-Boot only (ignores OTA profiles; security profiles still apply — `--uboot secure-boot` emits the signed U-Boot deb) |
| `--minimal` | CLI image, no desktop |
| `--no-usbplug` | Skip the RK Maskrom usbplug loader build |
| `-h, --help` | Usage |

## 4. Conflict rules

The wrapper rejects ([`build.sh:305-345`](../scripts/build.sh#L305)):
`--kernel` with `--minimal` or `--uboot`; `--uboot` with `--minimal`;
duplicate profiles; `recovery` with `ab`; `secure-boot` with `secure-rootfs`.
`--kernel`/`--uboot` ignore OTA profiles entirely.

## 5. Environment variables

### OTA partition sizing

Read in [`partitions.sh:24-44`](../armbian-ota/common/build-hooks/partitions.sh#L24);
the same policy applies to both OTA modes (sizes per partition; A/B has two
boot and two rootfs partitions).

| Variable | Default | Meaning |
|---|---|---|
| [`OTA_BOOT_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L31) | 512 | Boot partition(s), MiB |
| [`OTA_SECURITY_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L32) | 4 | Security partition (encrypted images), MiB |
| [`OTA_ROOTFS_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L34) | computed | Rootfs partition, MiB — `(built rootfs + EXTRA_ROOTFS_MIB_SIZE) + 50%` headroom |
| [`OTA_USERDATA_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L36) | 512 | Userdata partition, MiB — build-time floor, expanded to the full disk on first boot |
| `EXTRA_ROOTFS_MIB_SIZE` | 0 | Extra rootfs MiB added before headroom |

Boot size precedence is `OTA_BOOT_SIZE` > `BOOTSIZE` > 512 on every
layout; secure boot applies the same rule to its raw boot partition
([`rk-secure-boot.sh:104`](../rk_secure-disk-encryption/rk-secure-boot.sh#L104)).

### Encryption / secure boot

| Variable | Default | Meaning |
|---|---|---|
| `CRYPTROOT_PASSPHRASE` | required | The single secret. **Use exactly 64 hexadecimal characters** — see [05-encryption.md](05-encryption.md). Validated non-empty at [`build.sh:153`](../scripts/build.sh#L153) |
| `RK_OPTEE_BOOT_ENABLE` | unset | secure-rootfs tier (unsigned bootchain) |
| `RK_SECURE_UBOOT_ENABLE` | unset | secure-boot tier (signed chain + usbplug) |
| `RK_COMPILE_USBPLUG` | yes | Build the Maskrom usbplug loader |
| `UBOOT_FIT_KEYS_BACKUP_DIR` | unset | Reuse/persist FIT signing keys across builds — see [06-secure-boot.md](06-secure-boot.md) |
| `RK_SECURE_BOOT_MKIMAGE` | auto | Override the FIT signer binary (auto = signing-capable rkbin prebuilt) |
| `DISABLE_FIT_KEY_GEN` | unset | Skip key generation; incompatible with full secure boot ([`secure-boot-uboot.sh:394`](../rk_secure-disk-encryption/build-hooks/secure-boot-uboot.sh#L394)) |
| `RK_SECURE_KERNEL_DTB` | unset | Override the kernel DTB packed into the FIT |
| [`RK_SECURE_BOOT_ROOTARGS`](../rk_secure-disk-encryption/build-hooks/secure-boot-image.sh#L14) | `root=/dev/mapper/armbian-root rw rootwait` | Kernel root bootargs |
| [`RK_SECURE_BOOT_EXTRA_BOOTARGS`](../rk_secure-disk-encryption/build-hooks/secure-boot-image.sh#L15) | unset | Extra kernel bootargs |
| `DEFAULT_OVERLAYS` | unset | Overlays baked into the FIT DTB at build time (secure-boot images have no `/boot` filesystem, so runtime dtbo loading is impossible) |

### Tooling sources

| Variable | Default | Meaning |
|---|---|---|
| [`RKSDK_TOOLS_GIT_URL`](../rk_secure-disk-encryption/build-hooks/common.sh#L10) | Seeed `rockchip_sdk_tools` fork | Source of rkbin prebuilts (mkimage, OP-TEE clients, sign tools) |
| `RKSDK_TOOLS_BRANCH` | `main` | Branch of the above |
| `SEEED_RK_EXTENSION_OFFLINE`, `OFFLINE_WORK`, `APT_PROXY_ADDR=none` | unset | Offline/reproducible build helpers; the wrapper unsets HTTP proxies itself and forwards these |
| `UBOOT_GIT_CACHE_TTL`, `KERNEL_GIT_CACHE_TTL`, mirrors (`DEBIAN_MIRROR`, `GITHUB_MIRROR`, `GHCR_MIRROR`, …) | unset | Forwarded to the build when set — see [`build.sh:178-199`](../scripts/build.sh#L178) |

### What the wrapper does not pass on

`CRYPTROOT_PASSPHRASE` reaches the build container via Docker `--env`, never
on the command line, so it stays out of `argv`/logs
([`build.sh:155`](../scripts/build.sh#L155)).

## 6. Caches and rebuild cost

| Cache | Contents | Cleared by |
|---|---|---|
| Kernel | `output/debs/linux-*-vendor-*.deb`, `output/packages-hashed/kernel-*`, `cache/sources/linux-kernel-worktree` | `-c, --clear-kernel-cache` ([`build.sh:358`](../scripts/build.sh#L358)) |
| Rootfs | `cache/rootfs/rootfs-arm64-*.tar.zst` | `-r, --clear-rootfs-cache` ([`build.sh:366`](../scripts/build.sh#L366)) |
| U-Boot | `output/debs/linux-u-boot-<board>-<branch>[-secure]_*.deb` + hashed artifacts | automatic on every usbplug build ([`build.sh:375`](../scripts/build.sh#L375)) |

Notes:

- The first build populates all caches (~1 h+); cached rebuilds skip the
  heavy steps entirely.
- The secure U-Boot lives in its own `-secure` package namespace, so one
  tree can produce and keep both variants
  ([`build.sh:105-121`](../scripts/build.sh#L105)).
- usbplug builds always clear the U-Boot cache: a cache hit would skip
  `uboot_custom_postprocess`, and `spl_loader_maskrom.bin` would never be
  regenerated ([`build.sh:372-375`](../scripts/build.sh#L372)).
