#!/bin/sh
#
# initramfs-tools init-top hook: unlock encrypted root from the security partition.

export SECURITY_STORAGE=SECURITY

BN_DIR="/dev/block/by-name"
SYSPW_FILE="/tmp/syspw"
MAPPER_NAME="armbian-root"
TEE_SUPPLICANT_PID=""

log_step() {
    echo "$*"
    [ -e /dev/kmsg ] && echo "$*" > /dev/kmsg 2>/dev/null || true
}

first_line() {
    while IFS= read -r line; do
        printf '%s\n' "$line"
        return 0
    done
    return 1
}

get_cmdline_crypt_uuid() {
    local token value

    for token in $(cat /proc/cmdline 2>/dev/null); do
        case "$token" in
            cryptdevice=UUID=*:*)
                value="${token#cryptdevice=UUID=}"
                echo "${value%%:*}"
                return 0
                ;;
            cryptdevice=UUID=*)
                echo "${token#cryptdevice=UUID=}"
                return 0
                ;;
        esac
    done

    return 1
}

get_cmdline_ab_slot() {
    local token

    for token in $(cat /proc/cmdline 2>/dev/null); do
        case "$token" in
            armbian.slot=a|armbian.slot=b)
                echo "${token#armbian.slot=}"
                return 0
                ;;
        esac
    done

    return 1
}

# Disk U-Boot actually loaded the OS image from, passed on the kernel command
# line by the bootcmd common prefix (armbian.bootdev/armbian.bootdevnum).
# Identical cloned images on several disks expose duplicate PARTLABELs and LUKS
# UUIDs, so a plain blkid first-match may address the wrong disk; partition
# lookups below are anchored to this disk when the tokens are present.
get_cmdline_boot_disk() {
    local token devtype devnum

    for token in $(cat /proc/cmdline 2>/dev/null); do
        case "$token" in
            armbian.bootdev=*) devtype="${token#armbian.bootdev=}" ;;
            armbian.bootdevnum=*) devnum="${token#armbian.bootdevnum=}" ;;
        esac
    done

    case "${devtype:-}" in
        mmc)
            [ -b "/dev/mmcblk${devnum:-}" ] || return 1
            echo "/dev/mmcblk${devnum}"
            ;;
        nvme)
            [ -b "/dev/nvme${devnum:-}n1" ] || return 1
            echo "/dev/nvme${devnum}n1"
            ;;
        *)
            return 1
            ;;
    esac
}

# First blkid device match for KEY=value, restricted to partitions of $disk
# (mmcblkNpX / nvmeXn1pY naming) when a disk is given, otherwise the plain
# first line (legacy single-disk behavior).
first_match_on_disk() {
    local filter="$1" disk="$2"

    if [ -n "$disk" ]; then
        blkid -t "$filter" -o device 2>/dev/null |
            grep -E "^${disk}p[0-9]+$" | first_line || true
    else
        blkid -t "$filter" -o device 2>/dev/null | first_line || true
    fi
}

# Parent disk of a partition device via sysfs (e.g. mmcblk1p3 -> mmcblk1).
# Works for partition nodes only; returns 1 for whole disks or dm devices.
parent_disk_of() {
    local partdev="$1" base parent_sys parent_name

    case "${partdev}" in
        /dev/*) ;;
        *) partdev="/dev/${partdev}" ;;
    esac
    [ -e "${partdev}" ] || return 1
    base="$(basename "${partdev}")"
    [ -L "/sys/class/block/${base}" ] || return 1
    [ -f "/sys/class/block/${base}/partition" ] || return 1
    parent_sys="$(dirname "$(readlink -f "/sys/class/block/${base}")")"
    parent_name="$(basename "${parent_sys}")"
    [ -e "/sys/class/block/${parent_name}/dev" ] || return 1
    printf '%s\n' "/dev/${parent_name}"
}

# First crypto_LUKS match for the PARTLABEL, across all blkid matches.
get_luks_device_by_partlabel() {
    local partlabel="$1"
    local anchor_disk="${2:-${BOOT_DISK:-}}"
    local dev

    for dev in $(blkid -t "PARTLABEL=$partlabel" -o device 2>/dev/null); do
        [ "$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)" = "crypto_LUKS" ] || continue
        if [ -n "${anchor_disk}" ]; then
            case "${dev}" in
                "${anchor_disk}"p[0-9]*) ;;
                *) continue ;;
            esac
        fi
        printf '%s\n' "${dev}"
        return 0
    done
    return 1
}

unlock_luks_device() {
    local device="$1"
    local mapper_name="$2"
    local description="$3"

    /sbin/cryptsetup luksOpen "$device" "$mapper_name" < "$SYSPW_FILE" || {
        log_step "[Decryption-disk] Error: Failed to unlock ${description}"
        return 1
    }
}

keybox_ready() {
    [ -x /usr/bin/keybox_app ] &&
        [ -x /usr/bin/tee-supplicant ] &&
        [ -e /dev/tee0 ] &&
        [ -e /dev/teepriv0 ]
}

start_tee_supplicant() {
    keybox_ready || return 1
    /usr/bin/tee-supplicant >/dev/null 2>&1 &
    TEE_SUPPLICANT_PID="$!"
    log_step "[Decryption-disk] tee-supplicant started"
}

stop_tee_supplicant() {
    if [ -n "$TEE_SUPPLICANT_PID" ] && kill -0 "$TEE_SUPPLICANT_PID" 2>/dev/null; then
        kill "$TEE_SUPPLICANT_PID" >/dev/null 2>&1 || true
        wait "$TEE_SUPPLICANT_PID" 2>/dev/null || true
    fi
    TEE_SUPPLICANT_PID=""
}

log_step "[Decryption-disk] ENTER 0-decryption-disk"

BOOT_DISK="$(get_cmdline_boot_disk || true)"
if [ -n "$BOOT_DISK" ]; then
    log_step "[Decryption-disk] Boot disk from cmdline: ${BOOT_DISK}"
else
    log_step "[Decryption-disk] No boot disk token on cmdline, using device scan order"
fi

SECURITY_DEV="$(first_match_on_disk PARTLABEL=security "${BOOT_DISK:-}" || true)"
if [ -z "$SECURITY_DEV" ]; then
    log_step "[Decryption-disk] Error: cannot resolve security partition by PARTLABEL=security"
    blkid 2>/dev/null || true
    exit 1
fi

mkdir -p "$BN_DIR" 2>/dev/null || true
ln -sf "$SECURITY_DEV" "${BN_DIR}/security" 2>/dev/null || true
log_step "[Decryption-disk] security partition resolved: ${SECURITY_DEV}"

rm -f "$SYSPW_FILE" 2>/dev/null || true
SECURITY_MARKER="$(dd if="$SECURITY_DEV" bs=1 count=4 2>/dev/null || true)"
log_step "[Decryption-disk] Security partition marker: ${SECURITY_MARKER:-<empty>}"

if [ "$SECURITY_MARKER" = "SSKR" ]; then
    log_step "[Decryption-disk] SSKR marker found, reading passphrase with keybox_app"
    if ! start_tee_supplicant; then
        log_step "[Decryption-disk] Error: SSKR marker requires working OP-TEE and keybox_app"
        exit 1
    fi

    if ! /usr/bin/keybox_app >/dev/null 2>&1; then
        stop_tee_supplicant
        log_step "[Decryption-disk] Error: keybox_app read failed"
        exit 1
    fi
    stop_tee_supplicant
else
    # First-boot raw passphrase window. Every auto-decrypt image boots with
    # OP-TEE BL32 packed in its U-Boot FIT, so a genuine boot always has
    # /dev/tee* by the time this hook runs. A plain U-Boot provides no BL32
    # and can only have launched this kernel unverified -- refusing to hand
    # out the raw passphrase (and the rootfs) in that state closes the
    # loader-swap window while the passphrase is still stored in plaintext.
    if ! keybox_ready; then
        log_step "[Decryption-disk] Error: loader/OS mismatch: no OP-TEE/BL32 under this loader"
        panic "Decryption-disk: this image requires a secure loader (BL32). Boot halted; rootfs stays locked."
    fi
    log_step "[Decryption-disk] No SSKR marker, reading raw passphrase"
    dd if="$SECURITY_DEV" of="$SYSPW_FILE" bs=1 count=64 2>/dev/null || {
        log_step "[Decryption-disk] Error: failed to read raw passphrase"
        exit 1
    }
    chmod 600 "$SYSPW_FILE" 2>/dev/null || true

    if ! start_tee_supplicant; then
        log_step "[Decryption-disk] Error: tee-supplicant failed on the raw passphrase path"
        exit 1
    fi
    # Best-effort migration into the TEE keybox (keybox_app write rewrites
    # the partition as an SSKR container). Failure keeps the raw copy for
    # this boot and retries on the next one; the gate above still blocks
    # any later boot under a BL32-less loader.
    if ! /usr/bin/keybox_app write >/dev/null 2>&1; then
        log_step "[Decryption-disk] keybox_app write failed, keeping raw passphrase for this boot"
    fi
    stop_tee_supplicant
fi

if [ ! -s "$SYSPW_FILE" ]; then
    log_step "[Decryption-disk] Error: Failed to retrieve password from security partition"
    exit 1
fi
log_step "[Decryption-disk] Password successfully retrieved from security partition"

# Hand the passphrase to userspace: OTA needs it to derive the payload key, but
# keybox_app cannot read rk_secure_storage after switch_root on NVMe (no RPMB).
# /run is a tmpfs mounted in the initramfs and moved across switch_root, so this
# file survives into the booted system; it is ram-only and cleared on shutdown.
mkdir -p /run
if cp "$SYSPW_FILE" /run/armbian-luks-passphrase 2>/dev/null; then
    chmod 600 /run/armbian-luks-passphrase 2>/dev/null
else
    log_step "[Decryption-disk] WARN: failed to stash passphrase for OTA at /run"
fi

ROOT_DEVICE=""
TARGET_LUKS_UUID="$(get_cmdline_crypt_uuid || true)"
if [ -n "$TARGET_LUKS_UUID" ]; then
    ROOT_DEVICE="$(first_match_on_disk "UUID=$TARGET_LUKS_UUID" "${BOOT_DISK:-}" || true)"
    if [ -n "$ROOT_DEVICE" ] && [ "$(blkid -s TYPE -o value "$ROOT_DEVICE" 2>/dev/null || true)" != "crypto_LUKS" ]; then
        ROOT_DEVICE=""
    fi
fi

# A/B images use a stable GPT PARTLABEL for each slot. The LUKS UUID is
# device-local and may differ from the UUID known when a signed boot.itb was
# built, so select the requested slot before falling back to arbitrary LUKS
# discovery. First boot has no persistent U-Boot environment yet and defaults
# to the populated A slot.
if [ -z "$ROOT_DEVICE" ]; then
    AB_SLOT="$(get_cmdline_ab_slot || true)"
    case "$AB_SLOT" in
        a|b)
            ROOT_DEVICE="$(get_luks_device_by_partlabel "rootfs_$AB_SLOT" || true)"
            ;;
        *)
            ROOT_DEVICE="$(get_luks_device_by_partlabel "rootfs_a" || true)"
            ;;
    esac
fi

if [ -z "$ROOT_DEVICE" ]; then
    ROOT_DEVICE="$(get_luks_device_by_partlabel rootfs || true)"
fi

[ -n "$ROOT_DEVICE" ] || ROOT_DEVICE="$(first_match_on_disk TYPE=crypto_LUKS "${BOOT_DISK:-}" || true)"
if [ -z "$ROOT_DEVICE" ]; then
    log_step "[Decryption-disk] Error: No LUKS partition found"
    blkid 2>/dev/null || true
    exit 1
fi

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEVICE" 2>/dev/null || true)"
log_step "[Decryption-disk] Found LUKS device: ${ROOT_DEVICE} (UUID: ${ROOT_UUID:-unknown})"
log_step "[Decryption-disk] Unlocking LUKS encrypted partition"

unlock_luks_device "$ROOT_DEVICE" "$MAPPER_NAME" "root LUKS partition" || {
    exit 1
}

log_step "[Decryption-disk] root mapper ready: /dev/mapper/${MAPPER_NAME}"
log_step "[Decryption-disk] LUKS partition unlocked successfully"

# Anchor the userdata lookup to the disk the root LUKS partition was just
# unlocked from, so root and userdata always come from the same physical
# disk even when the root resolution took a fallback path.
USERDATA_DEVICE="$(get_luks_device_by_partlabel userdata "$(parent_disk_of "${ROOT_DEVICE}")" || true)"
if [ -n "$USERDATA_DEVICE" ]; then
    log_step "[Decryption-disk] Found encrypted userdata: ${USERDATA_DEVICE}"
    if unlock_luks_device "$USERDATA_DEVICE" armbian-userdata "userdata LUKS partition"; then
        log_step "[Decryption-disk] userdata mapper ready: /dev/mapper/armbian-userdata"
    else
        log_step "[Decryption-disk] Error: encrypted userdata is required but could not be unlocked"
        exit 1
    fi
fi
