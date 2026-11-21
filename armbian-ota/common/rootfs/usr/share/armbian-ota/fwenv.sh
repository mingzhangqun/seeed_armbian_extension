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
OTA_FW_ENV_OFFSET="0x3f8000"        # CONFIG_ENV_OFFSET (vendor env_blk)
OTA_FW_ENV_REDUND_OFFSET="0x3f0000" # CONFIG_ENV_OFFSET_REDUND (redundant copy)
OTA_FW_ENV_SIZE="0x8000"            # CONFIG_ENV_SIZE

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

# Clean read = exit 0, no bad-CRC warning, non-empty list.
fw_env_read_clean() {
    err_file="${TMPDIR:-/tmp}/fwenv.probe.$$"

    env_out="$(fw_printenv -c "$1" 2> "${err_file}")" || {
        rm -f "${err_file}" 2>/dev/null || true
        return 1
    }
    if grep -qiE "bad crc|cannot read environment|failed to read environment" "${err_file}"; then
        rm -f "${err_file}" 2>/dev/null || true
        return 1
    fi
    rm -f "${err_file}" 2>/dev/null || true
    [ -n "${env_out}" ]
}

# Residue at 0x3f0000 proves a redundant U-Boot (single-copy never writes it).
fw_env_redund_area_written() {
    [ -b "$1" ] || return 1
    dd if="$1" bs=512 skip=$((OTA_FW_ENV_REDUND_OFFSET / 512)) \
        count=$((OTA_FW_ENV_SIZE / 512)) 2>/dev/null \
        | tr -d '\377' | grep -q .
}

# Probe env format via exclusive CRC spans; never default to single.
fw_env_probe_redundant() {
    probe_disk="$1"

    probe_cfg="$(mktemp 2>/dev/null)" || return 1
    printf '%s\t%s\t%s\n' "${probe_disk}" "${OTA_FW_ENV_OFFSET}" "${OTA_FW_ENV_SIZE}" \
        > "${probe_cfg}" 2>/dev/null || {
        rm -f "${probe_cfg}" 2>/dev/null || true
        return 1
    }
    if fw_env_read_clean "${probe_cfg}"; then
        rm -f "${probe_cfg}" 2>/dev/null || true
        return 1
    fi
    printf '%s\t%s\t%s\n' "${probe_disk}" "${OTA_FW_ENV_REDUND_OFFSET}" "${OTA_FW_ENV_SIZE}" \
        >> "${probe_cfg}" 2>/dev/null
    if fw_env_read_clean "${probe_cfg}"; then
        rm -f "${probe_cfg}" 2>/dev/null || true
        return 0
    fi
    rm -f "${probe_cfg}" 2>/dev/null || true
    fw_env_redund_area_written "${probe_disk}"
}

# (Re)write /etc/fw_env.config for boot disk $1. Idempotent; the second
# (redundant) entry only when the disk's blob proves the U-Boot reads it.
fw_env_write_config() {
    disk="$1"

    [ -b "${disk}" ] || return 1
    mkdir -p "$(dirname "${OTA_FW_ENV_CONFIG}")" 2>/dev/null || return 1
    {
        printf '%s\t%s\t%s\n' "${disk}" "${OTA_FW_ENV_OFFSET}" "${OTA_FW_ENV_SIZE}"
        if fw_env_probe_redundant "${disk}"; then
            printf '%s\t%s\t%s\n' "${disk}" "${OTA_FW_ENV_REDUND_OFFSET}" "${OTA_FW_ENV_SIZE}"
        fi
    } > "${OTA_FW_ENV_CONFIG}" || return 1
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

# Bad CRC = stderr warning (wording varies); empty blob also counts as bad.
fw_env_crc_bad() {
    err_file="${TMPDIR:-/tmp}/fwenv.crc.$$"

    env_list="$(fw_printenv 2> "${err_file}")" || true
    if grep -qiE "bad crc|cannot read environment|failed to read environment" "${err_file}"; then
        rm -f "${err_file}" 2>/dev/null || true
        return 0
    fi
    rm -f "${err_file}" 2>/dev/null || true
    [ -z "${env_list}" ]
}

# Sanitize a bad-CRC copy with the build-generated rescue blob.
fw_env_repair_blob() {
    set -- $(awk 'NR==1 && !/^#/ {print $1, $2, $3; exit}' "${OTA_FW_ENV_CONFIG}" 2>/dev/null)
    [ -b "$1" ] || return 1
    fw_env_repair_disk="$1"
    fw_env_repair_off="${2:-${OTA_FW_ENV_OFFSET}}"
    fw_env_repair_sz="${3:-${OTA_FW_ENV_SIZE}}"

    [ "${fw_env_repair_sz}" = "0x8000" ] || return 1

    if [ -n "$(sed -n '2,$p' "${OTA_FW_ENV_CONFIG}" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -m1 '[^[:space:]]')" ]; then
        fw_env_repair_bin="/usr/share/armbian-ota/env-sanitize-redundant.bin"
    else
        fw_env_repair_bin="/usr/share/armbian-ota/env-sanitize-single.bin"
    fi
    [ -s "${fw_env_repair_bin}" ] || return 1

    dd if="${fw_env_repair_bin}" of="${fw_env_repair_disk}" \
        bs=512 seek=$((fw_env_repair_off / 512)) conv=notrunc 2>/dev/null || return 1
    return 0
}

# Flip one CRC bit: U-Boot falls back to the default env (Rescue).
fw_env_poison_crc() {
    set -- $(awk 'NR==1 && !/^#/ {print $1, $2, $3; exit}' "${OTA_FW_ENV_CONFIG}" 2>/dev/null)
    [ -b "$1" ] || return 1
    fw_env_poison_off="${2:-${OTA_FW_ENV_OFFSET}}"
    byte="$(dd if="$1" bs=1 skip=$((fw_env_poison_off)) count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')"
    [ -n "${byte}" ] || return 1
    printf "$(printf '\\%03o' $((byte ^ 255)))" \
        | dd of="$1" bs=1 seek=$((fw_env_poison_off)) count=1 conv=notrunc 2>/dev/null
}

# Set one variable and verify by readback.
fw_env_set() {
    key="$1"
    value="$2"

    fw_setenv "${key}" "${value}" || return 1
    [ "$(fw_env_get "${key}")" = "${value}" ] || return 1
    return 0
}

# --full-set only for whole-env rewrites; partial would drop bootcmd.
fw_env_set_multi() {
    full_set=0
    if [ "${1:-}" = "--full-set" ]; then
        full_set=1
        shift
    fi

    script_file="$(mktemp 2>/dev/null)" || return 1

    for kv in "$@"; do
        printf '%s\n' "${kv}" >> "${script_file}"
    done

    set_err="${TMPDIR:-/tmp}/fwenv.set.$$.err"
    fw_setenv -s "${script_file}" 2>"${set_err}" || {
        # script_file must survive until the retry below consumes it.
        if [ "${full_set}" -eq 0 ] || \
           ! { grep -qiE "bad crc|cannot read environment|failed to read environment" "${set_err}" || fw_env_crc_bad; }; then
            # Partial writers, and any failure that is not a confirmed
            # bad-CRC refusal, fail with the blob untouched.
            cat "${set_err}" >&2
            rm -f "${set_err}" "${script_file}" 2>/dev/null || true
            return 1
        fi
        rm -f "${set_err}" 2>/dev/null || true
        # trixie libubootenv refuses to write a bad-CRC env; sanitize the
        # blob to a valid rescue env and retry once (full-set callers only).
        echo "fwenv: WARNING sanitizing env blob (bad CRC) before full-set rewrite" >&2
        fw_env_repair_blob 2>/dev/null || true
        fw_setenv -s "${script_file}" || {
            # Leave a BAD CRC, not the valid-empty one: U-Boot falls back to
            # the compiled default env (Rescue) instead of hanging at boot.
            fw_env_poison_crc 2>/dev/null || true
            rm -f "${script_file}" 2>/dev/null || true
            return 1
        }
    }
    rm -f "${set_err}" "${script_file}" 2>/dev/null || true

    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        [ "$(fw_env_get "${key}")" = "${value}" ] || return 1
    done
    return 0
}

# ===== routing set ============================================================
# Single source: prefill and the runtime rebuild share these strings.
#
# Why a full set exists here: fw_setenv on a bad-CRC env starts from an EMPTY
# environment, so a CRC-rebuild that writes only ota_in_progress/ota_boot_next
# would silently drop bootcmd -- and the compiled default bootcmd routes to
# Rescue unconditionally, which means an endless Rescue loop. Every rebuild
# restores all entries atomically.
#
# Rescue comes in two flavors behind one dispatcher:
#   ota_rescue_boot_fs  -- ext4 boot partition carrying /recovery/{Image,
#                          uInitrd,board.dtb}; raw `booti` (plain recovery)
#   ota_rescue_boot_fit -- raw-FIT layout (secure boot): the rescue kernel is
#                          the same signed boot.itb, flashed to the dedicated
#                          PARTLABEL=recovery partition and booted with the
#                          vendor `boot_fit` command (signature verification
#                          included), mirroring the A/B raw-fit slot boot
# Rescue assets are mutually exclusive: plain uses ext4 /recovery/, while
# secure/raw-FIT uses its signed recovery partition. The dispatcher is selected
# below from the build-time layout stamp, never by trying an unsigned FIT.
#
# Normal boot likewise uses the layout-selected fs or signed FIT branch.
# The compiled default env carries only rescue scripts: on a bad-CRC boot it
# enters Rescue, whose CRC reconciliation rebuilds the full routing set.

OTA_ENV_NORMAL_BOOT_FS='setenv prefix /; ext4load ${devtype} ${devnum}:1 ${scriptaddr} /boot.scr && source ${scriptaddr}'
# The FIT's signed DTB supplies the build-configured console/root/extra
# bootargs. Only the dynamic disk and Rescue-role tokens belong in this script;
# a second hardcoded copy would override RK_SECURE_BOOT_* customizations.
OTA_ENV_NORMAL_BOOT_FIT='setenv boot_fit_part boot; env set bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum}"; boot_fit'
# Routes come from the build-stamped layout; plain FIT keys are refusal stubs.
OTA_ENV_NORMAL_BOOT='run ota_normal_boot_fs'
OTA_ENV_RESCUE_BOOT_FIT='setenv boot_fit_part recovery; env set bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum} armbian.ota_role=recovery"; boot_fit'
# Rescue fs script skeleton; @ROOT@ is spliced by fw_env_splice_root at
# routing-set build time (LABEL=armbi_root plain, mapper on encrypted).
OTA_ENV_RESCUE_BOOT_FS_TMPL='ext4load ${devtype} ${devnum}:1 ${kernel_addr_r} /recovery/Image && ext4load ${devtype} ${devnum}:1 ${ramdisk_addr_r} /recovery/uInitrd && ext4load ${devtype} ${devnum}:1 ${fdt_addr_r} /recovery/board.dtb && setenv bootargs "root=@ROOT@ rootwait rootfstype=ext4 console=ttyFIQ0,1500000n8 armbian.bootdev=${devtype} armbian.bootdevnum=${devnum} armbian.ota_role=recovery" && booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}'
OTA_ENV_RESCUE_BOOT='run ota_rescue_boot_fs || run distro_bootcmd'

# OTA_BOOT_MODE wins over the stamp; the failed read must stay exit-0.
if [ -n "${OTA_BOOT_MODE:-}" ]; then
    ota_fw_layout="${OTA_BOOT_MODE}"
else
    ota_fw_layout="$(cat /usr/share/armbian-ota/boot-mode 2>/dev/null || true)"
fi
if [ "${ota_fw_layout}" = "raw-fit" ]; then
    OTA_ENV_NORMAL_BOOT='run ota_normal_boot_fit'
    OTA_ENV_RESCUE_BOOT='run ota_rescue_boot_fit'
else
    OTA_ENV_NORMAL_BOOT_FIT='echo "PLAIN: raw FIT boot refused"'
    OTA_ENV_RESCUE_BOOT_FIT='echo "PLAIN: raw FIT boot refused"'
fi
OTA_ENV_BOOTCMD='if test -z "${devtype}"; then run rkimg_bootdev; fi; if test "${ota_in_progress}" = "1"; then if test "${ota_boot_next}" = "normal"; then setenv ota_boot_next recovery; if saveenv; then run ota_normal_boot; fi; run ota_rescue_boot; else run ota_rescue_boot; fi; else run ota_normal_boot; run ota_rescue_boot; fi'

# Rescue root for the fs branch, resolved at routing-set build time:
# LABEL=armbi_root on plain ext4 layouts; /dev/mapper/armbian-root on
# encrypted ones, where the LUKS container carries no filesystem label and
# only the init-top unlock provides a mountable root. Callers set
# OTA_RESCUE_ROOT_DEFAULT before fw_env_write_routing_set (the Rescue sets
# it from AUTO_DECRYPT_MODE; the build prefill from its layout config).
OTA_RESCUE_ROOT_DEFAULT="${OTA_RESCUE_ROOT_DEFAULT:-LABEL=armbi_root}"

# Write the complete routing env with the given flag values
# ($1 = ota_in_progress, $2 = ota_boot_next). Readback-verified.
fw_env_splice_root() {
    # $1 = rescue root spliced into the @ROOT@ placeholder
    printf '%s' "${OTA_ENV_RESCUE_BOOT_FS_TMPL}" | sed "s|@ROOT@|$1|"
}

fw_env_write_routing_set() {
    in_prog="$1"
    next="$2"

    rescue_fs="$(fw_env_splice_root "${OTA_RESCUE_ROOT_DEFAULT}")"

    fw_env_set_multi --full-set \
        "ota_in_progress=${in_prog}" \
        "ota_boot_next=${next}" \
        "ota_normal_boot_fs=${OTA_ENV_NORMAL_BOOT_FS}" \
        "ota_normal_boot_fit=${OTA_ENV_NORMAL_BOOT_FIT}" \
        "ota_normal_boot=${OTA_ENV_NORMAL_BOOT}" \
        "ota_rescue_boot_fs=${rescue_fs}" \
        "ota_rescue_boot_fit=${OTA_ENV_RESCUE_BOOT_FIT}" \
        "ota_rescue_boot=${OTA_ENV_RESCUE_BOOT}" \
        "bootcmd=${OTA_ENV_BOOTCMD}"
}
