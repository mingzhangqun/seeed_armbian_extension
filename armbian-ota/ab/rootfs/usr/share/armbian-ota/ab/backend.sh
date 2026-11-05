#!/bin/bash

ota_source_library "${OTA_RUNTIME_DIR}/ab/env.sh" "A/B U-Boot environment helper" || return 1
ota_source_library "${OTA_RUNTIME_DIR}/ab/target.sh" "A/B target update helper" || return 1

ab_require_tools() {
    ota_require_runtime fw_printenv fw_setenv blkid mount umount mountpoint tar findmnt sed grep awk reboot dd od tr blockdev
}

ab_ensure_slot_boot_env() {
    local init_script="/usr/lib/armbian/armbian-ota-init-uboot"

    if ab_env_slot_boot_ready; then
        return 0
    fi

    [ -x "${init_script}" ] || error_exit "AB boot env is not initialized and ${init_script} is missing"
    log_warn "AB boot env is incomplete, trying to repair via ${init_script} --force"
    "${init_script}" --force || error_exit "Failed to reinitialize AB boot env"
    ab_env_slot_boot_ready || error_exit "AB boot env is still invalid after reinitialization"
}

ab_require_partition_label() {
    local label="$1"
    local dev

    dev="$(ab_get_part_by_label "${label}")"
    [ -n "${dev}" ] || error_exit "AB OTA requires partition label ${label}, but it was not found"
}

ab_validate_environment() {
    local current_slot

    ab_ensure_slot_boot_env
    ab_require_partition_label "${BOOT_A_LABEL}"
    ab_require_partition_label "${BOOT_B_LABEL}"
    ab_require_partition_label "${ROOT_A_LABEL}"
    ab_require_partition_label "${ROOT_B_LABEL}"

    current_slot="$(ab_get_current_root_slot 2>/dev/null || true)"
    case "${current_slot}" in
        a|b) ;;
        *) error_exit "Current rootfs is not running from an AB root partition" ;;
    esac
}

# Slot helpers
ab_get_current_slot() {
    local current_slot

    current_slot="$(ab_get_current_root_slot 2>/dev/null || true)"
    if [ -n "${current_slot}" ]; then
        echo "${current_slot}"
        return 0
    fi

    current_slot="$(ab_env_get "boot_slot")"
    case "${current_slot}" in
        a|b) echo "${current_slot}" ;;
        *) echo "a" ;;
    esac
}

ab_get_target_slot() {
    ab_other_slot "$(ab_get_current_slot)"
}

# Public A/B OTA commands
ab_start_ota() {
    local package_path="$1"
    local current_slot target_slot target_root_label target_boot_label temp_work

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start <ota-package.tar.gz>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    ab_require_tools
    assert_package_mode_matches "${package_path}" "ab"
    ab_validate_environment

    current_slot="$(ab_get_current_slot)"
    target_slot="$(ab_get_target_slot)"
    target_boot_label="$(ab_get_slot_boot_label "${target_slot}")"
    target_root_label="$(ab_get_slot_root_label "${target_slot}")"

    if [ "$(ab_env_get ota_in_progress)" = "1" ]; then
        error_exit "Another AB OTA boot verification is still in progress"
    fi

    ota_assert_dual_payload "${package_path}"

    temp_work="$(make_ota_work_dir "ab-package")"
    extract_ota_package "${package_path}" "${temp_work}"
    ota_assert_payload_matches_system "${temp_work}"
    ota_verify_payload "${temp_work}" \
        "${OTA_PAYLOAD_ROOTFS_TAR}" "${OTA_PAYLOAD_ROOTFS_SHA}" \
        "${OTA_PAYLOAD_BOOT_TAR}" "${OTA_PAYLOAD_BOOT_SHA}" "${OTA_PAYLOAD_BOOT_ITB}"
    ota_check_package_requirements "${temp_work}"
    ota_run_phase1_hooks "${temp_work}"

    ab_update_target_partition "${temp_work}" "${target_root_label}" "${target_boot_label}" "${package_path}" "${current_slot}"
    rm -rf "${temp_work}"

    state_mark_prepared "ab" "ready_to_boot" "${package_path}" "${current_slot}" "${target_slot}" ||
        error_exit "Failed to mark AB OTA ready to boot"
    ab_env_prepare "${target_slot}" || error_exit "Failed to prepare U-Boot A/B state"

    log_info "AB OTA staged successfully. Current slot=${current_slot}, target slot=${target_slot}"
    log_info "Reboot to boot the new slot"
}

ab_mark_success() {
    local current_slot
    ab_require_tools

    if [ "$(state_get OTA_MODE)" != "ab" ] && [ "$(ab_env_get ota_in_progress)" != "1" ]; then
        log_info "No A/B OTA in progress, nothing to mark"
        return 0
    fi

    current_slot="$(ab_get_current_slot)"
    ab_env_mark_success "${current_slot}" || error_exit "Failed to mark A/B boot successful"
    state_mark_completed "ab" "success" "${current_slot}" "" ||
        error_exit "Failed to record successful A/B OTA state"

    log_info "AB OTA marked successful on slot ${current_slot}"
}

ab_rollback() {
    local last_success
    ab_require_tools

    if [ "$(ab_env_get ota_in_progress)" != "1" ]; then
        log_info "No A/B OTA in progress, nothing to rollback"
        return 0
    fi

    last_success="$(ab_env_get boot_success)"
    [ -n "${last_success}" ] || last_success="a"
    ab_env_rollback || error_exit "Failed to restore A/B boot state"
    state_mark_completed "ab" "rollback" "${last_success}" "" ||
        error_exit "Failed to record A/B rollback state"

    log_info "Rollback configured, rebooting back to slot ${last_success}"
    sync
    reboot
}

ab_switch_slot() {
    local target_slot="$1"
    local current_slot target_boot_label target_root_label

    ab_require_tools
    current_slot="$(ab_get_current_slot)"
    [ -n "${target_slot}" ] || target_slot="$(ab_get_target_slot)"

    case "${target_slot}" in
        a|b) ;;
        *) error_exit "Usage: armbian-ota switch-slot [a|b]" ;;
    esac

    if [ "$(ab_env_get ota_in_progress)" = "1" ]; then
        error_exit "Cannot switch slots while A/B OTA is in progress"
    fi

    target_boot_label="$(ab_get_slot_boot_label "${target_slot}")"
    target_root_label="$(ab_get_slot_root_label "${target_slot}")"
    [ -n "$(ab_get_part_by_label "${target_boot_label}")" ] || error_exit "Cannot find target boot partition: ${target_boot_label}"
    [ -n "$(ab_get_part_by_label "${target_root_label}")" ] || error_exit "Cannot find target root partition: ${target_root_label}"

    if [ "${current_slot}" = "${target_slot}" ]; then
        log_info "Already booting slot ${target_slot}"
        return 0
    fi

    ab_env_mark_success "${target_slot}" || error_exit "Failed to switch A/B boot state"
    state_mark_completed "ab" "slot_switched" "${current_slot}" "${target_slot}" ||
        error_exit "Failed to record A/B slot switch state"

    log_info "Boot slot switched from ${current_slot} to ${target_slot}; reboot to apply"
}

ab_status() {
    local current_slot ota_in_progress
    current_slot="$(ab_get_current_slot)"
    ota_in_progress="$(ab_env_get ota_in_progress)"

    echo "=== Armbian OTA Status (A/B) ==="
    echo "Mode: ab"
    echo "Status: $(state_get STATUS)"
    echo "Current slot: ${current_slot}"
    echo "Target slot: $(state_get TARGET_SLOT)"
    echo ""
    echo "U-Boot Environment:"
    echo "  boot_slot: $(ab_env_get boot_slot)"
    echo "  boot_success: $(ab_env_get boot_success)"
    echo "  ota_in_progress: ${ota_in_progress}"
    echo "  slot_retry_max: $(ab_env_initial_get slot_retry_max)"
    echo "  slot_retry_left: $(ab_env_get slot_retry_left)"
    echo ""
    echo "Partitions:"
    for label in "${BOOT_A_LABEL}" "${BOOT_B_LABEL}" "${ROOT_A_LABEL}" "${ROOT_B_LABEL}"; do
        local dev uuid mark slot
        dev="$(ab_get_part_by_label "${label}")"
        uuid=""
        [ -n "${dev}" ] && uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null | head -n1)"
        mark=""
        slot="$(ab_get_slot_by_label "${label}")" || slot=""
        if [ "${slot}" = "${current_slot}" ]; then
            mark=" [BOOTING]"
        fi
        echo "  ${label}: ${dev:-NOT FOUND} ${uuid:+(UUID: ${uuid})}${mark}"
    done
}
