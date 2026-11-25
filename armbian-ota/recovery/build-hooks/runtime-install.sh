# Recovery OTA rootfs and initramfs installation hooks

# fw_setenv -f rebuild base; 99-copy-tools stages it into the initramfs.
function ota_recovery_write_initial_env() {
    local root_dir="$1" default_env

    default_env="$(ota_default_env_file_for_rootfs "${root_dir}")" || {
        display_alert "Recovery OTA runtime" "U-Boot default env not found; fw_setenv merge base not installed" "err"
        return 1
    }

    install -D -m 0644 "${default_env}" "${root_dir}/etc/u-boot-initial-env" || {
        display_alert "Recovery OTA runtime" "Failed to install /etc/u-boot-initial-env" "err"
        return 1
    }
    display_alert "Recovery OTA runtime" "Installed /etc/u-boot-initial-env merge base" "info"
}

function ota_install_recovery_runtime_to_rootfs() {
    local root_dir="$1"
    local title="Recovery OTA runtime"

    ota_install_common_runtime_to_rootfs "${root_dir}" || return 1
    ota_sync_rootfs "${title}" "${OTA_RECOVERY_ROOTFS}" "${root_dir}"
    ota_recovery_write_initial_env "${root_dir}" || return 1
    ota_enable_rootfs_service "${root_dir}" armbian-ota-firstboot-hook.service "${title}"
    ota_enable_rootfs_service "${root_dir}" armbian-ota-health.service "${title}"
}

# The /boot fstab entry is removed by pre_update_initramfs__896 below;
# zz-seeed-mount-boot (initramfs) mounts /boot anchored to the rootfs disk.
function ota_install_recovery_initramfs() {
    local root_dir="$1"
    local title="Recovery OTA initramfs"
    local -a initramfs_file_list=(
        "hooks/99-copy-tools:etc/initramfs-tools/hooks/99-copy-tools:0755"
        "scripts/init-premount/99-ota-apply:etc/initramfs-tools/scripts/init-premount/99-ota-apply:0755"
        "scripts/init-bottom/99-ota-normal-marker:etc/initramfs-tools/scripts/init-bottom/99-ota-normal-marker:0755"
        "recovery/log.sh:etc/initramfs-tools/ota/recovery/log.sh:0644"
        "recovery/device.sh:etc/initramfs-tools/ota/recovery/device.sh:0644"
        "recovery/payload.sh:etc/initramfs-tools/ota/recovery/payload.sh:0644"
    )

    display_alert "${title}" "Preparing recovery OTA hooks for initramfs" "info"

    ota_install_common_initramfs "${root_dir}" \
        "scripts/init-bottom/zz-seeed-mount-boot:etc/initramfs-tools/scripts/init-bottom/zz-seeed-mount-boot:0755" || return 1

    ota_install_file_list "${title}" "${OTA_RECOVERY_INITRAMFS}" "${root_dir}" \
        "${initramfs_file_list[@]}" || return 1
}

function pre_update_initramfs__894_install_recovery_ota_hooks() {
    ota_install_recovery_runtime_to_rootfs "${MOUNT}" || return 1
    # ota_raw_boot_enabled uses the same raw-layout inputs as the rescue
    # hook; BOOT_RAW_MODE alone may not survive across Armbian hook rounds.
    # The stamp must exist before update_initramfs invokes 99-copy-tools.
    if ota_raw_boot_enabled; then
        ota_rescue_stamp_boot_mode "raw-fit"
    else
        ota_rescue_stamp_boot_mode "filesystem"
    fi
    ota_install_recovery_initramfs "${MOUNT}"
}

# Remove the /boot fstab entry: /boot is mounted by the initramfs
# (zz-seeed-mount-boot, anchored to the rootfs disk) instead. A fstab source
# is unworkable in multi-disk clone setups -- a UUID flips between clones
# through udev's duplicate-UUID symlinks, and a hand-made /dev symlink never
# satisfies systemd's udev-backed device unit (observed as a ~90s stall in
# "Expecting device dev-armbian-boot.device" and unbootable eMMC images).
# Raw-FIT (secure boot) layouts never get a /boot entry, so the grep does not
# match there.
function pre_update_initramfs__896_recovery_boot_anchor_fstab() {
    local fstab="${MOUNT}/etc/fstab"

    [[ -f "${fstab}" ]] || return 0
    if grep -qE '^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)' "${fstab}"; then
        sed -i -E '\@^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)@d' "${fstab}" ||
            exit_with_error "Recovery OTA" "failed to remove fstab /boot entry"
        display_alert "Recovery OTA" "removed fstab /boot entry (initramfs mounts /boot anchored)" "info"
    fi
}
