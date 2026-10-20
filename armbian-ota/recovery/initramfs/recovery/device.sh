#!/bin/sh
#
# Recovery initramfs source: block device / partition / UUID / LUKS / FIT probing.
#
# Sourced by 99-ota-apply after recovery/log.sh (primitives are silent; only
# ota_detect_devices logs). /bin/sh + busybox (blkid, udevadm).

# ===== helper: get DEV + UUID by LABEL (e.g. /dev/mmcblk0p5 + UUID) =====
# Optional $2 restricts the match to partitions of that disk: cloned images on
# several disks expose duplicate LABELs and a first blkid match may address
# the wrong disk.
get_dev_and_uuid_by_label() {
    label="$1"
    disk="${2:-}"
    if [ -n "${disk}" ]; then
        dev="$(blkid -t LABEL="${label}" -o device 2>/dev/null | grep -E "^${disk}p[0-9]+$" | head -n1)"
    else
        dev="$(blkid -t LABEL="${label}" -o device 2>/dev/null | head -n1)"
    fi
    [ -n "${dev}" ] || return 1
    uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null | head -n1)"
    [ -n "${uuid}" ] || return 1
    printf '%s %s\n' "${dev}" "${uuid}"
}

get_uuid_by_label() {
    set -- $(get_dev_and_uuid_by_label "$1" "${2:-}" 2>/dev/null) || return 1
    [ -n "$2" ] || return 1
    printf '%s\n' "$2"
}

# Disk U-Boot actually loaded the image from, passed on the kernel command
# line by the raw-fit bootcmd prefix (armbian.bootdev/armbian.bootdevnum).
# Cloned images on several disks expose duplicate PARTLABELs/LABELs/UUIDs,
# so an unanchored first match may address the wrong disk; the lookups below
# prefer partitions of this disk when the tokens are present, and keep the
# legacy first-match otherwise (single disk, older bootcmd).
recovery_boot_disk() {
    local token devtype devnum

    for token in $(cat /proc/cmdline 2>/dev/null); do
        case "${token}" in
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
# (mmcblkNpX / nvmeXn1pY naming) when a disk is given.
first_match_on_disk() {
    local filter="$1" disk="$2"

    if [ -n "${disk}" ]; then
        blkid -t "${filter}" -o device 2>/dev/null |
            grep -E "^${disk}p[0-9]+$" | head -n1
    else
        blkid -t "${filter}" -o device 2>/dev/null | head -n1
    fi
}

# ===== helper: get LUKS UUID for encrypted root backing device =====
# Anchored: prefer the container the initramfs actually unlocked (its sysfs
# slaves entry names the backing partition), then PARTLABEL=rootfs / any LUKS
# container restricted to the boot disk. Unanchored first-match remains the
# last resort for images without the cmdline tokens.
get_luks_uuid_for_root() {
    local root_luks_dev disk _dm _slave

    root_luks_dev=""
    if [ -e /dev/mapper/armbian-root ]; then
        for _dm in /sys/class/block/dm-*; do
            [ -e "${_dm}" ] || continue
            [ "$(cat "${_dm}/dm/name" 2>/dev/null)" = "armbian-root" ] || continue
            for _slave in "${_dm}/slaves/"*; do
                [ -e "${_slave}" ] || continue
                root_luks_dev="/dev/$(sed -n 's/^DEVNAME=//p' "${_slave}/uevent" 2>/dev/null | head -n1)"
                break
            done
            break
        done
    fi

    if [ -z "${root_luks_dev}" ] || [ "$(blkid -s TYPE -o value "${root_luks_dev}" 2>/dev/null || true)" != "crypto_LUKS" ]; then
        disk="$(recovery_boot_disk || true)"
        root_luks_dev="$(first_match_on_disk "PARTLABEL=rootfs" "${disk}" || true)"
        if [ -z "${root_luks_dev}" ] || [ "$(blkid -s TYPE -o value "${root_luks_dev}" 2>/dev/null || true)" != "crypto_LUKS" ]; then
            root_luks_dev="$(first_match_on_disk "TYPE=crypto_LUKS" "${disk}" || true)"
        fi
    fi

    [ -n "${root_luks_dev}" ] || return 1
    blkid -s UUID -o value "${root_luks_dev}" 2>/dev/null | head -n1
}

get_partname_for_dev() {
    dev="$1"
    base="$(basename "${dev}")"
    uevent="/sys/class/block/${base}/uevent"

    [ -f "${uevent}" ] || return 1
    sed -n 's/^PARTNAME=//p' "${uevent}" | head -n1
}

find_raw_boot_dev() {
    local disk devname partname uevent

    # Cloned disks each carry a PARTNAME=boot partition; boot.itb must land on
    # the disk U-Boot booted from, so restrict the scan to its partitions.
    disk="$(recovery_boot_disk || true)"
    for uevent in /sys/class/block/*/uevent; do
        [ -f "${uevent}" ] || continue
        devname="$(sed -n 's/^DEVNAME=//p' "${uevent}" | head -n1)"
        partname="$(sed -n 's/^PARTNAME=//p' "${uevent}" | head -n1)"
        [ -n "${devname}" ] || continue
        [ "${partname}" = "boot" ] || continue
        if [ -n "${disk}" ]; then
            case "/dev/${devname}" in
                "${disk}"p*) ;;
                *) continue ;;
            esac
        fi
        printf '/dev/%s\n' "${devname}"
        return 0
    done
    return 1
}

blockdev_size_bytes() {
    dev="$1"
    base="$(basename "${dev}")"
    sectors_file="/sys/class/block/${base}/size"

    [ -f "${sectors_file}" ] || return 1
    sectors="$(cat "${sectors_file}" 2>/dev/null)"
    [ -n "${sectors}" ] || return 1
    echo $((sectors * 512))
}

file_size_bytes() {
    file="$1"

    wc -c < "${file}" 2>/dev/null | awk '{print $1}'
}

is_fit_image() {
    file="$1"

    magic="$(dd if="${file}" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "${magic}" = "d00dfeed" ]
}

# ===== detect firmware mode and root/boot devices =====
# Sets globals: ROOT_DEV, ROOT_UUID, BOOT_DEV, BOOT_UUID, HAS_BOOT_PART,
# AUTO_DECRYPT_MODE. ROOT_DEV stays empty when detection fails (caller skips).
ota_detect_devices() {
    ROOT_DEV=""
    ROOT_UUID=""
    BOOT_DEV=""
    BOOT_UUID=""
    HAS_BOOT_PART=0
    AUTO_DECRYPT_MODE=0

    # Wait for block devices to settle before probing. In init-premount the root
    # partition node may not have appeared yet (mmc scan can lag the hook by ~1s),
    # which previously made blkid miss LABEL=armbi_root and silently skip OTA.
    udevadm settle --timeout=10 2>/dev/null || true

    # Command-line root= of this boot, parsed once: the auto-decrypt gate
    # below and the standard-mode root detection further down both consume it.
    cmdline_root=""
    for _tok in $(cat /proc/cmdline 2>/dev/null); do
        case "${_tok}" in
            root=*) cmdline_root="${_tok#root=}"; break ;;
        esac
    done

    # Detect auto-decrypt mode. The unlock itself happens in the init-top
    # decryption-disk hook, which runs before this init-premount hook and
    # hard-stops the boot on failure: a genuine auto-decrypt boot normally
    # reaches here with /dev/mapper/armbian-root already open. Wait-worthy
    # signals, in order: the open mapper, firmware asking for it on the
    # cmdline (root=/dev/mapper/* or cryptdevice=UUID=*), or a cmdline
    # root= that resolves to a crypto_LUKS container. A bare blkid
    # crypto_LUKS hit is NOT one: with several disks attached, a LUKS
    # container on a non-boot disk (e.g. a plain SD boot with an encrypted
    # eMMC left installed) used to trigger the full 30s mapper wait on
    # every plain boot of that chassis -- delaying root mount, and with
    # late udev module loads racing the unused-regulator shutdown,
    # bricking the boot outright.
    luks_signal=""
    if [ -e /dev/mapper/armbian-root ]; then
        luks_signal="mapper already open"
    else
        case "${cmdline_root}" in
            /dev/mapper/*) luks_signal="cmdline root=${cmdline_root}" ;;
        esac
        if [ -z "${luks_signal}" ]; then
            for _tok in $(cat /proc/cmdline 2>/dev/null); do
                case "${_tok}" in
                    cryptdevice=UUID=*) luks_signal="cmdline ${_tok}"; break ;;
                esac
            done
        fi
        if [ -z "${luks_signal}" ]; then
            luks_root_dev=""
            case "${cmdline_root}" in
                UUID=*)
                    luks_root_dev="$(first_match_on_disk "UUID=${cmdline_root#UUID=}" "$(recovery_boot_disk || true)")"
                    ;;
                LABEL=*)
                    luks_root_dev="$(get_dev_and_uuid_by_label "${cmdline_root#LABEL=}" "$(recovery_boot_disk || true)" || true)"
                    luks_root_dev="${luks_root_dev%% *}"
                    ;;
                /dev/*)
                    luks_root_dev="${cmdline_root}"
                    ;;
            esac
            if [ -n "${luks_root_dev}" ] && [ -e "${luks_root_dev}" ] && \
               [ "$(blkid -s TYPE -o value "${luks_root_dev}" 2>/dev/null || true)" = "crypto_LUKS" ]; then
                luks_signal="cmdline root=${cmdline_root} resolves to LUKS container ${luks_root_dev}"
            fi
        fi
    fi

    if [ -n "${luks_signal}" ]; then
        log "auto-decrypt candidate detected (${luks_signal}), waiting for /dev/mapper/armbian-root"
        timeout=30
        elapsed=0
        while [ ! -e /dev/mapper/armbian-root ] && [ "${elapsed}" -lt "${timeout}" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if [ -e /dev/mapper/armbian-root ]; then
            AUTO_DECRYPT_MODE=1
            ROOT_DEV="/dev/mapper/armbian-root"
            ROOT_UUID="$(get_luks_uuid_for_root || true)"
            log "auto-decrypt mode: ROOT_DEV=${ROOT_DEV}, LUKS_UUID=${ROOT_UUID:-<empty>}"
        else
            log "WARN: LUKS container present but mapper not ready after ${timeout}s, fallback to standard mode"
        fi
    else
        log "no auto-decrypt signal (mapper, cmdline root=/cryptdevice=), using standard recovery OTA mode"
    fi

    boot_info="$(get_dev_and_uuid_by_label "armbi_boot" "$(recovery_boot_disk || true)" || true)"

    if [ "${AUTO_DECRYPT_MODE}" -eq 0 ]; then
        # Standard mode root detection, in anchoring order:
        #   1. The inherited initramfs ROOT when init-top/armbian-bootdev-root
        #      already rewrote it (through /conf/param.conf) into the concrete
        #      partition on the disk U-Boot booted from. Re-resolving
        #      root=UUID= through an unanchored blkid first-match races on
        #      dd-cloned disks whose duplicate UUIDs point ROOT_DEV at a disk
        #      the firmware never booted from -- and this hook mkfs/extracts
        #      onto ROOT_DEV below.
        #   2. cmdline root= (always present, independent of device probe
        #      timing), with UUID resolution restricted to the bootdev token
        #      disk when the tokens are present.
        #   3. LABEL=armbi_root fallback, likewise token-anchored.
        root_info=""

        case "${ROOT:-}" in
            /dev/*)
                if [ -b "${ROOT}" ]; then
                    _ruuid="$(blkid -s UUID -o value "${ROOT}" 2>/dev/null | head -n1)"
                    # Distrust a ROOT that disagrees with cmdline root=UUID=:
                    # only the bootdev anchor may legitimately rewrite it.
                    case "${cmdline_root}" in
                        UUID=*) [ "${_ruuid}" = "${cmdline_root#UUID=}" ] || _ruuid="" ;;
                    esac
                    if [ -n "${_ruuid}" ]; then
                        root_info="${ROOT} ${_ruuid}"
                        log "using initramfs-anchored ROOT=${ROOT}"
                    fi
                fi
                ;;
        esac

        if [ -z "${root_info}" ] && [ -n "${cmdline_root}" ]; then
            log "cmdline root= detected: ${cmdline_root}"
            case "${cmdline_root}" in
                UUID=*)
                    _cuuid="${cmdline_root#UUID=}"
                    _cdev=""
                    _i=0
                    while [ "${_i}" -lt 10 ]; do
                        _cdev="$(first_match_on_disk "UUID=${_cuuid}" "$(recovery_boot_disk || true)")"
                        [ -n "${_cdev}" ] && break
                        sleep 1
                        _i=$((_i + 1))
                    done
                    if [ -n "${_cdev}" ]; then
                        root_info="${_cdev} ${_cuuid}"
                    else
                        log "WARN: cmdline root=UUID=${_cuuid} unresolved after 10s, fallback to LABEL"
                    fi
                    ;;
                LABEL=*)
                    _clbl="${cmdline_root#LABEL=}"
                    _cinfo="$(get_dev_and_uuid_by_label "${_clbl}" "$(recovery_boot_disk || true)" || true)"
                    [ -n "${_cinfo}" ] && root_info="${_cinfo}"
                    ;;
                /dev/*)
                    _cdev="${cmdline_root}"
                    _cuuid="$(blkid -s UUID -o value "${_cdev}" 2>/dev/null | head -n1)"
                    root_info="${_cdev} ${_cuuid}"
                    ;;
                *)
                    log "WARN: cmdline root= format not recognized: ${cmdline_root}"
                    ;;
            esac
        fi

        if [ -z "${root_info}" ]; then
            log "cmdline root= unavailable or unresolved, fallback to LABEL=armbi_root"
            root_info="$(get_dev_and_uuid_by_label "armbi_root" "$(recovery_boot_disk || true)" || true)"
        fi

        if [ -n "${root_info}" ]; then
            set -- $root_info
            ROOT_DEV="$1"
            ROOT_UUID="$2"
        fi
        log "standard mode root detection: ROOT_DEV=${ROOT_DEV}, ROOT_UUID=${ROOT_UUID}"
    else
        log "auto-decrypt mode root detection: skip armbi_root label probing"
    fi

    if [ -n "$boot_info" ]; then
        set -- $boot_info
        BOOT_DEV="$1"
        BOOT_UUID="$2"
        HAS_BOOT_PART=1
    fi

    log "auto-detected BOOT_DEV=${BOOT_DEV}, BOOT_UUID=${BOOT_UUID}, HAS_BOOT_PART=${HAS_BOOT_PART}"
}
