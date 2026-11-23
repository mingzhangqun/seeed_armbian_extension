# A/B U-Boot environment helpers.

readonly AB_INITIAL_ENV="/etc/u-boot-initial-env"

AB_PARTITIONS_LIB="${OTA_RUNTIME_DIR}/ab/partitions.sh"
[ -r "${AB_PARTITIONS_LIB}" ] || {
    echo "ERROR: A/B partition helper not found: ${AB_PARTITIONS_LIB}" >&2
    return 1
}
. "${AB_PARTITIONS_LIB}"

# fw_env_* helpers: shared with recovery via the common runtime.
FW_ENV_LIB="${OTA_RUNTIME_DIR}/fwenv.sh"
[ -r "${FW_ENV_LIB}" ] || {
    echo "ERROR: fw_env helper not found: ${FW_ENV_LIB}" >&2
    return 1
}
. "${FW_ENV_LIB}"

ab_env_get() {
    fw_env_get "$@"
}

# Batch write + readback via fw_env_set_multi (never rebuilds from empty).
ab_env_set() {
    local entry key value

    for entry in "$@"; do
        key="${entry%%=*}"
        value="${entry#*=}"
        if [ -z "${key}" ] || [ "${key}" = "${entry}" ]; then
            return 1
        fi
    done

    fw_env_set_multi "$@"
}

# Default environment initialization and repair.
ab_env_initial_get() {
    local key="$1"

    awk -v key="${key}" \
        'index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' \
        "${AB_INITIAL_ENV}"
}

ab_env_set_if_missing() {
    local key="$1" value="$2"

    [ -n "$(ab_env_get "${key}")" ] && return 0
    ab_env_set "${key}=${value}"
}

ab_env_apply_initial() {
    local key="$1" mode="${2:-missing}" value current

    value="$(ab_env_initial_get "${key}")"
    [ -n "${value}" ] || return 1

    current="$(ab_env_get "${key}")"
    case "${mode}" in
        missing) [ -n "${current}" ] && return 0 ;;
        sync) [ "${current}" = "${value}" ] && return 0 ;;
        *) return 1 ;;
    esac

    ab_env_set "${key}=${value}"
}

# Negation of the shared fw_env_crc_bad predicate.
ab_env_healthy() {
    ! fw_env_crc_bad
}

ab_env_initialize_default() {
    local current_slot="$1"

    ab_env_healthy && return 0
    [ -s "${AB_INITIAL_ENV}" ] || return 1
    fw_setenv -f "${AB_INITIAL_ENV}" boot_slot "${current_slot}" || return 1
    fw_setenv boot_success "${current_slot}"
}

ab_env_repair_defaults() {
    local current_slot="$1" key

    [ -s "${AB_INITIAL_ENV}" ] || return 1

    for key in ota_in_progress slot_retry_max slot_retry_left; do
        ab_env_apply_initial "${key}" || return 1
    done

    for key in ab_preboot ab_select_boot_part scan_dev_for_boot_part ab_select_fit_slot bootcmd; do
        ab_env_apply_initial "${key}" sync || return 1
    done

    ab_env_set_if_missing boot_slot "${current_slot}" || return 1
    ab_env_set_if_missing boot_success "${current_slot}"
}

# U-Boot environment validation.
ab_env_slot_boot_ready() {
    local bootcmd scan preboot devtype devnum part_a part_b boot_mode fit_selector boot_part_selector
    bootcmd="$(ab_env_get bootcmd)"
    scan="$(ab_env_get scan_dev_for_boot_part)"
    preboot="$(ab_env_get ab_preboot)"
    devtype="$(ab_env_get ab_boot_devtype)"
    devnum="$(ab_env_get ab_boot_devnum)"
    part_a="$(ab_env_get distro_bootpart_a)"
    part_b="$(ab_env_get distro_bootpart_b)"
    boot_mode="$(ab_env_get ab_boot_mode)"
    fit_selector="$(ab_env_get ab_select_fit_slot)"
    boot_part_selector="$(ab_env_get ab_select_boot_part)"

    [[ -n "${devtype}" && -n "${devnum}" &&
        -n "${part_a}" && -n "${part_b}" &&
        "${preboot}" == *slot_retry_left* &&
        "${preboot}" == *ota_in_progress* &&
        "${bootcmd}" == *"run ab_preboot"* &&
        "${bootcmd}" == *ab_boot_mode* ]] || return 1

    if [[ "${boot_mode}" == "raw-fit" ]]; then
        # armbian.bootdev token: bootcmd must pass the boot disk to the kernel
        # so initramfs/userspace anchor to the disk U-Boot actually booted
        # from. Its absence marks a legacy bootcmd that OTA re-inits via
        # armbian-ota-init-uboot --force.
        [[ "${fit_selector}" == *boot_fit_part* &&
            "${bootcmd}" == *"run ab_select_fit_slot"* &&
            "${bootcmd}" == *boot_fit* &&
            "${bootcmd}" == *armbian.bootdev* ]]
        return
    fi

    [[ "${boot_part_selector}" == *ab_boot_devtype* &&
        "${boot_part_selector}" == *boot_slot* &&
        "${scan}" == *"run ab_select_boot_part"* &&
        "${bootcmd}" == *"run distro_bootcmd"* ]]
}

ab_env_prepare() {
    local slot="$1"
    local retry_max

    case "${slot}" in
        a|b) ;;
        *) return 1 ;;
    esac
    retry_max="$(ab_env_initial_get slot_retry_max)"
    [ -n "${retry_max}" ] || return 1
    ab_env_set "ota_in_progress=1" "boot_slot=${slot}" \
        "slot_retry_max=${retry_max}" "slot_retry_left=${retry_max}"
}

ab_env_mark_success() {
    local slot="${1:-}"
    local retry_max

    [ -n "${slot}" ] || slot="$(ab_get_current_root_slot 2>/dev/null || true)"
    case "${slot}" in
        a|b) ;;
        *) return 1 ;;
    esac
    retry_max="$(ab_env_initial_get slot_retry_max)"
    [ -n "${retry_max}" ] || return 1
    # boot_slot must be set so U-Boot's ab_select_boot_part / ab_select_fit_slot
    # pick the slot on next reset; switch-slot uses ab_env_prepare instead so
    # its target remains an unconfirmed boot trial until health checks pass.
    ab_env_set "boot_slot=${slot}" "boot_success=${slot}" "ota_in_progress=0" \
        "slot_retry_left=${retry_max}"
}

ab_env_rollback() {
    local slot
    local retry_max

    slot="$(ab_env_get boot_success)"
    case "${slot}" in
        a|b) ;;
        *) return 1 ;;
    esac
    retry_max="$(ab_env_initial_get slot_retry_max)"
    [ -n "${retry_max}" ] || return 1
    ab_env_set "boot_slot=${slot}" "ota_in_progress=0" \
        "slot_retry_left=${retry_max}"
}
