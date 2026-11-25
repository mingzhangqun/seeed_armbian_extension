# A/B OTA rootfs installation hooks

function ota_ab_write_complete_initial_env() {
    local root_dir="$1"
    local default_env merged_env key

    default_env="$(ota_default_env_file_for_rootfs "${root_dir}")" || {
        display_alert "A/B U-Boot environment" "Packaged U-Boot default environment not found" "err"
        return 1
    }

    merged_env="$(mktemp)" || return 1
    ota_merge_uboot_env_files "${merged_env}" \
        "${default_env}" \
        "${OTA_AB_ROOTFS}/etc/u-boot-initial-env" || {
        rm -f "${merged_env}"
        return 1
    }

    grep -q '^distro_bootcmd=' "${merged_env}" &&
        grep -q '^scan_dev_for_boot=' "${merged_env}" &&
        grep -q '^scan_dev_for_boot_part=' "${merged_env}" || {
        rm -f "${merged_env}"
        return 1
    }

    # Every repair key must resolve here: a key the runtime spec lists but
    # the initial env lacks fails ab_env_repair_defaults on every boot.
    # shellcheck source=/dev/null
    source "${OTA_SUPPORT_DIR}/ab/rootfs/usr/share/armbian-ota/ab/env-keys.sh" || {
        rm -f "${merged_env}"
        return 1
    }
    for key in ${AB_ENV_MISSING_KEYS} ${AB_ENV_SYNC_KEYS}; do
        grep -q "^${key}=" "${merged_env}" || {
            display_alert "A/B U-Boot environment" "Initial env lacks repair key: ${key}" "err"
            rm -f "${merged_env}"
            return 1
        }
    done

    install -D -m 0644 "${merged_env}" "${root_dir}/etc/u-boot-initial-env" || {
        rm -f "${merged_env}"
        return 1
    }
    rm -f "${merged_env}"
}

function ota_install_ab_runtime_to_rootfs() {
    local root_dir="$1"

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1
    ota_sync_rootfs "A/B OTA runtime" "${OTA_AB_ROOTFS}" "${root_dir}"
    ota_ab_write_complete_initial_env "${root_dir}"
}

function ota_enable_ab_runtime_services() {
    local root_dir="$1"
    local title="A/B partition OTA"

    display_alert "${title}" "Enabling A/B OTA services" "info"
    ota_enable_rootfs_service "${root_dir}" armbian-ota-init-uboot.service "${title}"
    ota_enable_rootfs_service "${root_dir}" armbian-ota-firstboot.service "${title}"
    ota_enable_rootfs_service "${root_dir}" armbian-ota-firstboot-hook.service "${title}"
}

function pre_update_initramfs__895_install_ab_ota_runtime() {
    ota_install_ab_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_common_initramfs "${MOUNT}" || return 1
    ota_enable_ab_runtime_services "${MOUNT}"
}
