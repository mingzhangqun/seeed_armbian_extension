#!/bin/sh
# Shared helpers: locate the userdata partition anchored to a specific root
# device (typically the boot disk's rootfs partition).
#
# POSIX sh, works in initramfs (busybox) and runtime (bash). Used by:
#   - initramfs init-bottom/00-seeed-bind-userdata  (creates /dev/armbian-userdata symlink)
#   - runtime /usr/lib/armbian/armbian-resize-userdata (resize script)
#
# Why: with multiple disks each carrying an identical image, every disk has a
# partition labelled PARTLABEL=userdata. blkid | head -n1 picks arbitrarily,
# so initramfs may mount root-rw from a different disk than root-ro, and the
# resize service may resize the wrong disk. Anchoring to the root device
# makes the choice deterministic.

# Echo the parent disk of a partition device, using sysfs (no lsblk dep).
# Input: /dev/mmcblk1p2, /dev/nvme0n1p3, /dev/sda1, /dev/disk/by-uuid/...
# Output: /dev/mmcblk1, /dev/nvme0n1, /dev/sda, ...
# Returns 1 if the device is not a partition or cannot be resolved.
find_user_data__parent_disk() {
    partdev="$1"
    [ -n "${partdev}" ] || return 1

    case "${partdev}" in
        /dev/*) ;;
        *) partdev="/dev/${partdev}" ;;
    esac
    # Resolve symlinks (e.g. /dev/disk/by-label/armbi_root -> /dev/mmcblk1p1)
    # so the basename below refers to a real partition node, not a label.
    resolved="$(readlink -f "${partdev}" 2>/dev/null || true)"
    [ -n "${resolved}" ] && partdev="${resolved}"
    [ -e "${partdev}" ] || return 1

    base="$(basename "${partdev}")"
    sys_link="/sys/class/block/${base}"
    [ -L "${sys_link}" ] || return 1

    parent_sys="$(dirname "$(readlink -f "${sys_link}")")"
    parent_name="$(basename "${parent_sys}")"
    [ -n "${parent_name}" ] || return 1
    [ -e "/sys/class/block/${parent_name}/dev" ] || return 1

    printf '/dev/%s\n' "${parent_name}"
}

# Echo the userdata partition on the same physical disk as the given root
# device, filtered by PARTLABEL=userdata. Skips LUKS partitions (the
# unencrypted userdata is what overlayroot mounts directly).
# Input: root partition device path (e.g. /dev/mmcblk1p1)
# Output: /dev/<rootdisk>p<N> for the userdata partition
# Returns 1 if not found.
find_user_data__partition_for_root() {
    root_part="$1"
    [ -n "${root_part}" ] || return 1

    find_user_data__partlabel_on_root_disk "${root_part}" "userdata"
}

# Echo the partition carrying PARTLABEL=$label on the same physical disk as
# the given root device. Same multi-disk rationale as above: cloned disks
# duplicate every PARTLABEL, so an unfiltered blkid match is arbitrary.
# Skips LUKS partitions so raw-FIT/secure layouts never surface a container.
# Input: root partition device path, GPT partition label
# Output: /dev/<rootdisk>p<N>
# Returns 1 if not found.
find_user_data__partlabel_on_root_disk() {
    root_part="$1" label="$2"
    [ -n "${root_part}" ] || return 1
    [ -n "${label}" ] || return 1

    root_disk="$(find_user_data__parent_disk "${root_part}")" || return 1
    [ -n "${root_disk}" ] || return 1

    for dev in $(blkid -t PARTLABEL=${label} -o device 2>/dev/null); do
        [ "$(blkid -s TYPE -o value "${dev}" 2>/dev/null)" = "crypto_LUKS" ] && continue
        dev_disk="$(find_user_data__parent_disk "${dev}" 2>/dev/null)" || continue
        if [ "${dev_disk}" = "${root_disk}" ]; then
            printf '%s\n' "${dev}"
            return 0
        fi
    done
    return 1
}

# Resolve a kernel cmdline root= token to a concrete block device.
# Handles UUID=, LABEL=, PARTUUID=, /dev/... forms. Waits briefly for the
# device to appear.
find_user_data__resolve_root_token() {
    token="$1"
    [ -n "${token}" ] || return 1

    case "${token}" in
        UUID=*)
            link="/dev/disk/by-uuid/${token#UUID=}"
            ;;
        LABEL=*)
            link="/dev/disk/by-label/${token#LABEL=}"
            ;;
        PARTUUID=*)
            link="/dev/disk/by-partuuid/${token#PARTUUID=}"
            ;;
        /dev/*)
            link="${token}"
            ;;
        *)
            return 1
            ;;
    esac

    _i=0
    while [ "${_i}" -lt 10 ]; do
        if [ -L "${link}" ] || [ -b "${link}" ]; then
            readlink -f "${link}" 2>/dev/null || printf '%s\n' "${link}"
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

# Read root= from /proc/cmdline and resolve to a block device.
find_user_data__root_dev_from_cmdline() {
    [ -r /proc/cmdline ] || return 1
    for tok in $(cat /proc/cmdline); do
        case "${tok}" in
            root=*)
                token="${tok#root=}"
                find_user_data__resolve_root_token "${token}" && return 0
                return 1
                ;;
        esac
    done
    return 1
}

# Resolve any block device to its raw backing partition (dm: first
# slave; real mapper nodes: ls maj:min). Returns 1 for whole disks.
# Shared resolver for both lookup forms: the sysfs block name itself when
# it is a partition, else its first slave.
_find_user_data__sys_partition() {
    sys_base="$1"

    if [ -f "/sys/class/block/${sys_base}/partition" ]; then
        printf '/dev/%s\n' "${sys_base}"
        return 0
    fi
    if [ -d "/sys/class/block/${sys_base}/slaves" ]; then
        slave="$(ls "/sys/class/block/${sys_base}/slaves" 2>/dev/null | head -n1)"
        if [ -n "${slave}" ] && [ -f "/sys/class/block/${slave}/partition" ]; then
            printf '/dev/%s\n' "${slave}"
            return 0
        fi
    fi
    return 1
}

find_user_data__raw_partition_of() {
    dev="$1"
    case "${dev}" in
        /dev/*) ;;
        *) dev="/dev/${dev}" ;;
    esac
    resolved="$(readlink -f "${dev}" 2>/dev/null || true)"
    [ -n "${resolved}" ] && dev="${resolved}"
    [ -e "${dev}" ] || return 1

    _find_user_data__sys_partition "$(basename "${dev}")" && return 0

    # Real /dev/mapper nodes have no sysfs block name; map via maj:min.
    mm="$(ls -l "${dev}" 2>/dev/null | awk '{ gsub(",", "", $5); print $5 ":" $6 }')"
    case "${mm}" in
        [0-9]*:[0-9]*)
            sys_base="$(basename "$(readlink -f "/sys/dev/block/${mm}" 2>/dev/null || true)" 2>/dev/null)"
            [ -n "${sys_base}" ] && _find_user_data__sys_partition "${sys_base}" && return 0
            ;;
    esac
    return 1
}
