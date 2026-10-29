#!/bin/sh

# fw_env helpers shared by the normal system (armbian-ota CLI, health
# service) and the Rescue initramfs (99-ota-apply). POSIX sh + busybox.
#
# Plain recovery routing tokens (ota_in_progress / ota_boot_next) live in the
# single-copy vendor env blob at a raw offset below partition 1. Every write
# goes through fw_setenv and is verified by readback (design section 3.3);
# a bad-CRC env is detected explicitly and rebuilt from state, never blindly
# appended to (fw_setenv on a bad-CRC env starts from an EMPTY environment,
# which would silently drop every other variable).

OTA_FW_ENV_CONFIG="${OTA_FW_ENV_CONFIG:-/etc/fw_env.config}"
OTA_FW_ENV_OFFSET="0x3f8000"   # CONFIG_ENV_OFFSET (vendor env_blk)
OTA_FW_ENV_SIZE="0x8000"       # CONFIG_ENV_SIZE

# Whole-disk device backing partition device $1, via sysfs parent walk.
# /dev/mmcblk0p3 -> /dev/mmcblk0, /dev/nvme0n1p3 -> /dev/nvme0n1.
fw_env_parent_disk() {
    dev="$1"
    base="$(basename "${dev}")"
    sys_path="/sys/class/block/${base}"

    if [ -L "${sys_path}" ]; then
        parent="$(basename "$(readlink -f "${sys_path}/..")")"
        if [ -d "/sys/class/block/${parent}" ] && [ "${parent}" != "${base}" ]; then
            case "${parent}" in
                loop*|ram*|zram*) ;;
                *) printf '%s\n' "/dev/${parent}"; return 0 ;;
            esac
        fi
    fi

    # name-based fallback when sysfs walk is unavailable
    case "${base}" in
        mmcblk*p[0-9]*|nvme*n*p[0-9]*) printf '%s\n' "/dev/$(printf '%s' "${base}" | sed 's/p[0-9]*$//')" ;;
        sd[a-z][0-9]*|vd[a-z][0-9]*)    printf '%s\n' "/dev/$(printf '%s' "${base}" | sed 's/[0-9]*$//')" ;;
    esac
    return 1
}

fw_env_cmdline_value() {
    key="$1"
    sed -n "s/.*[[:space:]]${key}=\([^[:space:]]*\).*/\1/p" /proc/cmdline 2>/dev/null | head -n1
}

# Boot disk from the U-Boot cmdline anchor tokens (armbian.bootdev[+num],
# injected by the prefilled/rescue bootcmd). Falls back to $1 (the partition
# device the caller anchored: userdata in Rescue, lower rootfs in normal).
fw_env_boot_disk() {
    anchor_dev="${1:-}"

    devtype="$(fw_env_cmdline_value armbian.bootdev)"
    num="$(fw_env_cmdline_value armbian.bootdevnum)"
    if [ -n "${devtype}" ] && [ -n "${num}" ]; then
        case "${devtype}" in
            mmc)  [ -b "/dev/mmcblk${num}" ] && { printf '%s\n' "/dev/mmcblk${num}"; return 0; } ;;
            nvme) [ -b "/dev/nvme${num}n1" ] && { printf '%s\n' "/dev/nvme${num}n1"; return 0; } ;;
        esac
    fi

    [ -n "${anchor_dev}" ] && fw_env_parent_disk "${anchor_dev}"
}

# (Re)write /etc/fw_env.config for boot disk $1. Idempotent.
fw_env_write_config() {
    disk="$1"

    [ -b "${disk}" ] || return 1
    mkdir -p "$(dirname "${OTA_FW_ENV_CONFIG}")" 2>/dev/null || return 1
    printf '%s\t%s\t%s\n' "${disk}" "${OTA_FW_ENV_OFFSET}" "${OTA_FW_ENV_SIZE}" \
        > "${OTA_FW_ENV_CONFIG}" || return 1
    return 0
}

# Ensure a usable fw_env.config exists for boot disk resolution; returns the
# disk it selected via fw_env_boot_disk (stdout).
fw_env_ensure_config() {
    anchor_dev="${1:-}"

    disk="$(fw_env_boot_disk "${anchor_dev}")"
    [ -n "${disk}" ] || return 1

    if [ -f "${OTA_FW_ENV_CONFIG}" ]; then
        config_disk="$(awk 'NR==1 && !/^#/ {print $1; exit}' "${OTA_FW_ENV_CONFIG}" 2>/dev/null)"
        if [ "${config_disk}" = "${disk}" ]; then
            printf '%s\n' "${disk}"
            return 0
        fi
    fi

    fw_env_write_config "${disk}" || return 1
    printf '%s\n' "${disk}"
}

fw_env_get() {
    fw_printenv -n "$1" 2>/dev/null
}

# True when the persistent env blob fails its CRC check. fw_printenv still
# prints the (default) variables in that state, so the warning on stderr is
# the only reliable signal.
fw_env_crc_bad() {
    err_file="${TMPDIR:-/tmp}/fwenv.crc.$$"

    fw_printenv > /dev/null 2> "${err_file}" || true
    grep -qi "bad crc" "${err_file}"
    rc=$?
    rm -f "${err_file}" 2>/dev/null || true
    [ "${rc}" -eq 0 ]
}

# Set one variable and verify by readback.
fw_env_set() {
    key="$1"
    value="$2"

    fw_setenv "${key}" "${value}" || return 1
    [ "$(fw_env_get "${key}")" = "${value}" ] || return 1
    return 0
}

# Set multiple variables in one fw_setenv -s run and verify each by readback.
fw_env_set_multi() {
    script_file="$(mktemp 2>/dev/null)" || return 1

    for kv in "$@"; do
        printf '%s\n' "${kv}" >> "${script_file}"
    done

    fw_setenv -s "${script_file}" || {
        rm -f "${script_file}" 2>/dev/null || true
        return 1
    }
    rm -f "${script_file}" 2>/dev/null || true

    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        [ "$(fw_env_get "${key}")" = "${value}" ] || return 1
    done
    return 0
}

# ===== routing set ============================================================
# The five env entries that make plain-recovery routing work (transactional
# bootcmd + both boot scripts + the two flags). KEEP IN SYNC with the three
# producers: uboot-env-prefill.sh (persistent blob), the U-Boot default-env
# patch (seeed-ota-rescue-default-env.patch) and this file.
#
# Why a full set exists here: fw_setenv on a bad-CRC env starts from an EMPTY
# environment, so a CRC-rebuild that writes only ota_in_progress/ota_boot_next
# would silently drop bootcmd -- and the compiled default bootcmd routes to
# Rescue unconditionally, which means an endless Rescue loop. Every rebuild
# restores all five entries atomically.

OTA_ENV_NORMAL_BOOT='setenv prefix /; ext4load ${devtype} ${devnum}:1 ${scriptaddr} /boot.scr && source ${scriptaddr}'
OTA_ENV_RESCUE_BOOT='ext4load ${devtype} ${devnum}:1 ${kernel_addr_r} /recovery/Image && ext4load ${devtype} ${devnum}:1 ${ramdisk_addr_r} /recovery/uInitrd && ext4load ${devtype} ${devnum}:1 ${fdt_addr_r} /recovery/board.dtb && setenv bootargs "root=LABEL=armbi_root rootwait rootfstype=ext4 console=${console} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum} armbian.ota_role=recovery" && booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}'
OTA_ENV_BOOTCMD='if test -z "${devtype}"; then run rkimg_bootdev; fi; if test "${ota_in_progress}" = "1"; then if test "${ota_boot_next}" = "normal"; then setenv ota_boot_next recovery; if saveenv; then run ota_normal_boot; fi; run ota_rescue_boot; else run ota_rescue_boot; fi; else run ota_normal_boot; run ota_rescue_boot; fi'

# Write the complete routing env with the given flag values
# ($1 = ota_in_progress, $2 = ota_boot_next). Readback-verified.
fw_env_write_routing_set() {
    in_prog="$1"
    next="$2"

    fw_env_set_multi \
        "ota_in_progress=${in_prog}" \
        "ota_boot_next=${next}" \
        "ota_normal_boot=${OTA_ENV_NORMAL_BOOT}" \
        "ota_rescue_boot=${OTA_ENV_RESCUE_BOOT}" \
        "bootcmd=${OTA_ENV_BOOTCMD}"
}
