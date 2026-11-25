# A/B OTA rootfs installation hooks

readonly OTA_COMMON_INITRAMFS_AB="${OTA_SUPPORT_DIR}/common/initramfs"

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
    chroot "${root_dir}" systemctl enable armbian-ota-init-uboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-init-uboot.service" "warn"
    chroot "${root_dir}" systemctl enable armbian-ota-firstboot.service \
        || display_alert "${title}" "Failed to enable armbian-ota-firstboot.service" "warn"
    chroot "${root_dir}" systemctl enable armbian-ota-firstboot-hook.service \
        || display_alert "${title}" "Failed to enable armbian-ota-firstboot-hook.service" "warn"
}

# Install the Seeed OTA common initramfs pieces (userdata resolver) into an
# A/B image. Mirrors ota_install_common_initramfs in the recovery hook but
# is kept independent so the A/B path can evolve without coupling.
function ota_install_ab_common_initramfs() {
    local root_dir="$1"
    local title="A/B OTA common initramfs"
    local -a common_initramfs_file_list=(
        "hooks/98-seeed-bind-userdata:etc/initramfs-tools/hooks/98-seeed-bind-userdata:0755"
        "scripts/init-bottom/00-seeed-bind-userdata:etc/initramfs-tools/scripts/init-bottom/00-seeed-bind-userdata:0755"
    )
    local entry source_path destination_path mode

    display_alert "${title}" "Installing userdata resolver" "info"
    for entry in "${common_initramfs_file_list[@]}"; do
        IFS=: read -r source_path destination_path mode <<< "${entry}"
        [[ -f "${OTA_COMMON_INITRAMFS_AB}/${source_path}" ]] || {
            display_alert "${title}" "Missing source file: ${OTA_COMMON_INITRAMFS_AB}/${source_path}" "err"
            return 1
        }
        install -D -m "${mode}" \
            "${OTA_COMMON_INITRAMFS_AB}/${source_path}" \
            "${root_dir}/${destination_path}" || return 1
    done
}

function pre_update_initramfs__895_install_ab_ota_runtime() {
    ota_install_ab_runtime_to_rootfs "${MOUNT}" || return 1
    ota_install_ab_common_initramfs "${MOUNT}" || return 1
    ota_enable_ab_runtime_services "${MOUNT}"
}
