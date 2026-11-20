# A/B slot topology and partition discovery helpers.
# fwenv.sh provides the shared POSIX boot-disk/parent-disk primitives.

[ -r "${OTA_RUNTIME_DIR}/fwenv.sh" ] || {
    echo "ERROR: fw_env helper not found: ${OTA_RUNTIME_DIR}/fwenv.sh" >&2
    return 1
}
. "${OTA_RUNTIME_DIR}/fwenv.sh"

BOOT_A_LABEL="armbi_boota"
BOOT_B_LABEL="armbi_bootb"
ROOT_A_LABEL="armbi_roota"
ROOT_B_LABEL="armbi_rootb"

ab_other_slot() {
    case "$1" in
        a) echo "b" ;;
        b) echo "a" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_boot_label() {
    case "$1" in
        a) echo "${BOOT_A_LABEL}" ;;
        b) echo "${BOOT_B_LABEL}" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_root_label() {
    case "$1" in
        a) echo "${ROOT_A_LABEL}" ;;
        b) echo "${ROOT_B_LABEL}" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_by_label() {
    case "$1" in
        "${BOOT_A_LABEL}"|"${ROOT_A_LABEL}") echo "a" ;;
        "${BOOT_B_LABEL}"|"${ROOT_B_LABEL}") echo "b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_boot_partlabel() {
    case "$1" in
        a) echo "boot_a" ;;
        b) echo "boot_b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_root_partlabel() {
    case "$1" in
        a) echo "rootfs_a" ;;
        b) echo "rootfs_b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_by_root_partlabel() {
    case "$1" in
        rootfs_a) echo "a" ;;
        rootfs_b) echo "b" ;;
        *) return 1 ;;
    esac
}

ab_get_slot_partlabel_by_fslabel() {
    case "$1" in
        "${BOOT_A_LABEL}") ab_get_slot_boot_partlabel a ;;
        "${BOOT_B_LABEL}") ab_get_slot_boot_partlabel b ;;
        "${ROOT_A_LABEL}") ab_get_slot_root_partlabel a ;;
        "${ROOT_B_LABEL}") ab_get_slot_root_partlabel b ;;
        *) echo "" ;;
    esac
}

ab_resolve_physical_part_dev() {
    local dev="$1" physical_part

    [ -n "${dev}" ] || return 1

    case "${dev}" in
        /dev/mapper/*|/dev/dm-*)
            physical_part="$(lsblk -snro PATH,TYPE "${dev}" 2>/dev/null |
                awk '$2 == "part" { print $1; exit }')"
            if [ -n "${physical_part}" ]; then
                echo "${physical_part}"
                return 0
            fi
            ;;
    esac

    echo "${dev}"
}

# Disk U-Boot actually loaded the boot image from (cmdline tokens, shared
# impl in fwenv.sh). Identical cloned A/B images on several disks expose
# duplicate filesystem LABELs and PARTLABELs, so the discovery below prefers
# partitions of this disk; missing tokens keep first-match.
ab_boot_disk() {
    fw_env_boot_disk ""
}

# First blkid device match for KEY=value, restricted to partitions of $disk
# (mmcblkNpX / nvmeXn1pY naming) when a disk is given.
ab_blkid_first_on_disk() {
    local filter="$1" disk="$2"

    if [ -n "${disk}" ]; then
        blkid -t "${filter}" -o device 2>/dev/null |
            grep -E "^${disk}p[0-9]+$" | head -n1
    else
        blkid -t "${filter}" -o device 2>/dev/null | head -n1
    fi
}

ab_get_part_by_label() {
    local label="$1" dev partlabel disk

    disk="$(ab_boot_disk || true)"

    dev="$(ab_blkid_first_on_disk "LABEL=${label}" "${disk}")"
    if [ -n "${dev}" ]; then
        ab_resolve_physical_part_dev "${dev}"
        return 0
    fi

    partlabel="$(ab_get_slot_partlabel_by_fslabel "${label}")"
    if [ -n "${partlabel}" ]; then
        dev="$(ab_blkid_first_on_disk "PARTLABEL=${partlabel}" "${disk}")"
        if [ -n "${dev}" ]; then
            ab_resolve_physical_part_dev "${dev}"
            return 0
        fi
    fi

    echo ""
}

ab_get_fstype_by_dev() {
    local dev="$1"

    [ -n "${dev}" ] || return 1
    blkid -o value -s TYPE "${dev}" 2>/dev/null | head -n1
}

ab_get_partlabel_by_dev() {
    local dev="$1"

    [ -n "${dev}" ] || return 1
    blkid -o value -s PARTLABEL "${dev}" 2>/dev/null | head -n1
}

ab_get_uuid_by_dev() {
    local dev="$1"

    [ -n "${dev}" ] || return 1
    blkid -o value -s UUID "${dev}" 2>/dev/null | head -n1
}

ab_get_uuid_by_label() {
    local label="$1" dev uuid

    dev="$(ab_get_part_by_label "${label}")"
    if [ -n "${dev}" ]; then
        uuid="$(ab_get_uuid_by_dev "${dev}")"
        if [ -n "${uuid}" ]; then
            echo "${uuid}"
            return 0
        fi
    fi

    blkid -t LABEL="${label}" -o value -s UUID 2>/dev/null | head -n1
}

# Identify the running root slot by PARTLABEL, with a UUID fallback.
ab_get_current_root_slot() {
    local current_slot root_dev root_part root_partlabel root_uuid root_a_uuid root_b_uuid

    root_dev="$(findmnt -n -o SOURCE /media/root-ro 2>/dev/null || true)"
    [ -n "${root_dev}" ] || root_dev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [ -n "${root_dev}" ] || root_dev="$(df / | awk 'NR==2 {print $1}')"
    [ -n "${root_dev}" ] || return 1

    root_part="$(ab_resolve_physical_part_dev "${root_dev}" || true)"
    root_partlabel="$(ab_get_partlabel_by_dev "${root_part}" || true)"
    current_slot="$(ab_get_slot_by_root_partlabel "${root_partlabel}" || true)"
    if [ -n "${current_slot}" ]; then
        echo "${current_slot}"
        return 0
    fi

    root_uuid="$(ab_get_uuid_by_dev "${root_dev}" || true)"
    root_a_uuid="$(ab_get_uuid_by_label "${ROOT_A_LABEL}")"
    root_b_uuid="$(ab_get_uuid_by_label "${ROOT_B_LABEL}")"
    if [ -n "${root_uuid}" ] && [ "${root_uuid}" = "${root_a_uuid}" ]; then
        echo "a"
        return 0
    fi
    if [ -n "${root_uuid}" ] && [ "${root_uuid}" = "${root_b_uuid}" ]; then
        echo "b"
        return 0
    fi

    return 1
}
