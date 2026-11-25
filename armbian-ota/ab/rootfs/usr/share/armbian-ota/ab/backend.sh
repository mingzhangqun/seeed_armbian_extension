#!/bin/bash

ota_source_library "${OTA_RUNTIME_DIR}/ab/env.sh" "A/B U-Boot environment helper" || return 1
ota_source_library "${OTA_RUNTIME_DIR}/ab/target.sh" "A/B target update helper" || return 1

ab_require_tools() {
    ota_require_runtime fw_printenv fw_setenv blkid mount umount mountpoint tar findmnt sed grep awk reboot dd od tr blockdev df stat rm
}

# ===== staging store: the existing userdata overlay upper ====================
# A/B and Recovery both use userdata as overlayroot's writable upper. Reuse its
# existing /media/root-rw mount; unlocking or mounting the same ext4 again would
# give the running upper and the OTA transaction independent filesystem views.
AB_OVERLAY_BACKING_DIR="/media/root-rw"
AB_TRANSACTION_DIR="${AB_OVERLAY_BACKING_DIR}/ota-ab"

ab_prepare_staging() {
    mountpoint -q "${AB_OVERLAY_BACKING_DIR}" ||
        error_exit "A/B overlayroot backing store is unavailable: ${AB_OVERLAY_BACKING_DIR}"

    OTA_WORK_DIR="${AB_TRANSACTION_DIR}/ota_work"
    mkdir -p "${OTA_WORK_DIR}" ||
        error_exit "Cannot create A/B staging directory: ${OTA_WORK_DIR}"
    # The CLI lock rules out concurrent users, so earlier staging dirs are dead
    # weight. Keep completed package state on the running slot untouched.
    rm -rf "${OTA_WORK_DIR}"/ab-package.* ||
        error_exit "Cannot clean stale A/B staging directories in ${OTA_WORK_DIR}"
    log_info "Staging store: existing userdata overlay upper, OTA work dir is ${OTA_WORK_DIR}"
}

# ===== staging space gate ====================================================
ab_check_space() {
    local package_path="$1"

    load_package_env_metadata "${package_path}" ||
        error_exit "Cannot read OTA package metadata for staging estimation: ${package_path}"
    ota_check_staging_free_space "${OTA_WORK_DIR}" "${package_path}"
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

# Capacity gate: the payload must fit the TARGET slot partitions before any
# write. Encrypted targets are probed closed at start time, so the LUKS2
# header + keyslots area (16 MiB by default; reserved at 32 MiB) is
# subtracted as an allowance instead of measured.
ab_check_capacity() {
    local root_label="$1" boot_label="$2"
    local root_dev boot_dev root_allowance=0

    root_dev="$(ab_get_part_by_label "${root_label}")"
    boot_dev="$(ab_get_part_by_label "${boot_label}")"
    [ -n "${root_dev}" ] || error_exit "Capacity gate: cannot find target root partition ${root_label}"
    [ -n "${boot_dev}" ] || error_exit "Capacity gate: cannot find target boot partition ${boot_label}"

    if [ "$(blkid -o value -s TYPE "${root_dev}" 2>/dev/null)" = "crypto_LUKS" ]; then
        root_allowance=$((32 * 1024 * 1024))
    fi
    ota_check_payload_capacity "${root_dev}" "${boot_dev}" "${root_allowance}" 0
}

# Public A/B OTA commands
ab_start_ota() {
    local package_path="$1"
    local current_slot target_slot target_root_label target_boot_label temp_work

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start <ota-package.tar.gz>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    ab_require_tools
    assert_package_mode_matches "${package_path}" "ab"

    # Cheapest, most-likely rejection first: one fw_printenv read beats every
    # probe below, and a pending boot verification vetoes any new transaction.
    if [ "$(ab_env_get ota_in_progress)" = "1" ]; then
        error_exit "Another AB OTA boot verification is still in progress"
    fi

    ab_validate_environment

    current_slot="$(ab_get_current_slot)"
    target_slot="$(ab_get_target_slot)"
    target_boot_label="$(ab_get_slot_boot_label "${target_slot}")"
    target_root_label="$(ab_get_slot_root_label "${target_slot}")"
    ab_check_capacity "${target_root_label}" "${target_boot_label}"

    # Stage in the existing userdata overlay upper. Never open or mount its
    # backing ext4 a second time: it is already live at /media/root-rw.
    ab_prepare_staging
    ab_check_space "${package_path}"

    temp_work="$(make_ota_work_dir "ab-package")"
    extract_ota_package "${package_path}" "${temp_work}"
    ota_assert_dual_payload "${temp_work}"
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

ab_reconcile() {
    local status current_slot target_slot last_success

    ab_require_tools
    init_logging
    # state_init is normally idempotent. Redirect its output outside any log
    # command substitution, which would otherwise run it in a subshell and
    # lose first-time state-file creation.
    state_init >> "${OTA_LOG_FILE}" 2>&1
    [ "$(state_get OTA_MODE)" = "ab" ] || return 0
    status="$(state_get STATUS)"
    case "${status}" in
        ready_to_boot|boot_verifying) ;;
        *) return 0 ;;
    esac

    # A still-pending transaction belongs to the health check. This runs from
    # firstboot's ExecStartPost, which also runs when its ExecCondition skips
    # the health check after U-Boot has already cleared ota_in_progress.
    [ "$(ab_env_get ota_in_progress)" != "1" ] || return 0

    current_slot="$(ab_get_current_root_slot || true)"
    target_slot="$(state_get TARGET_SLOT)"
    last_success="$(ab_env_get boot_success)"
    case "${current_slot}" in
        a|b) ;;
        *)
            log_error "Cannot reconcile A/B OTA state: current root slot is unknown"
            return 1
            ;;
    esac

    if [ -n "${target_slot}" ] && [ "${current_slot}" != "${target_slot}" ] && [ "${current_slot}" = "${last_success}" ]; then
        # U-Boot cannot update this slot's state file after retry exhaustion.
        log_warn "A/B OTA target slot ${target_slot} did not pass boot verification; running confirmed slot ${current_slot}"
        state_mark_completed "ab" "rollback" "${current_slot}" "" ||
            error_exit "Failed to record U-Boot A/B rollback"
        log_info "A/B OTA rollback recorded; target slot cleared"
        return 0
    fi

    # Never infer success from ota_in_progress=0: it may have been cleared by
    # a power cut or manual fw_setenv before userspace verified the candidate.
    log_error "A/B OTA pending state ended without boot confirmation (current=${current_slot}, target=${target_slot:-unknown}, boot_success=${last_success:-unknown})"
    state_mark_completed "ab" "failed" "${current_slot}" "${target_slot}" ||
        error_exit "Failed to record unconfirmed A/B OTA state"
}

ab_rollback() {
    local last_success current_slot rollback_slot
    ab_require_tools

    if [ "$(ab_env_get ota_in_progress)" != "1" ]; then
        # Env flag may be zeroed by a dual-bad rebuild; state file is
        # authoritative then.
        current_slot="$(ab_get_current_root_slot 2>/dev/null || true)"
        case "${current_slot}" in
            a|b) ;;
            *)
                log_info "No A/B OTA in progress, nothing to rollback"
                return 0
                ;;
        esac
        rollback_slot="$(ab_env_rebuild_slot "${current_slot}")"
        if [ "${rollback_slot}" = "${current_slot}" ]; then
            log_info "No A/B OTA in progress, nothing to rollback"
            return 0
        fi
        last_success="${rollback_slot}"
        # Undo the rebuild's boot_success re-point before rolling back.
        ab_env_set "boot_success=${last_success}" ||
            error_exit "Failed to restore boot_success after env rebuild"
    else
        last_success="$(ab_env_get boot_success)"
        [ -n "${last_success}" ] || last_success="a"
    fi

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

    # A manual slot switch is a boot trial too: retain the last confirmed
    # slot as the rollback anchor and require first-boot health confirmation.
    # Do not mark the unbooted target successful, or a bad slot cannot roll
    # back and a following OTA would trust the wrong boot_success value.
    ab_env_prepare "${target_slot}" || error_exit "Failed to prepare A/B slot switch"
    state_mark_prepared "ab" "ready_to_boot" "manual-slot-switch" "${current_slot}" "${target_slot}" ||
        error_exit "Failed to record pending A/B slot switch"

    log_info "Boot slot switch requested from ${current_slot} to ${target_slot}; reboot to apply and verify"
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
