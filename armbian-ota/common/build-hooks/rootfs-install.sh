# Common OTA rootfs installation helpers

function ota_sync_rootfs() {
    local title="$1"
    local source_rootfs="$2"
    local target_rootfs="$3"

    if [[ ! -d "${source_rootfs}" ]]; then
        display_alert "${title}" "rootfs source dir missing: ${source_rootfs}" "err"
        return 1
    fi

    display_alert "${title}" "Installing ${source_rootfs}" "info"
    rsync -aH --chown=0:0 "${source_rootfs}/" "${target_rootfs}/" || {
        display_alert "${title}" "Failed to install ${source_rootfs}" "err"
        return 1
    }
}

function ota_install_common_runtime_to_rootfs() {
    ota_sync_rootfs "OTA runtime" "${OTA_COMMON_ROOTFS}" "$1" || return 1
    printf 'IMAGE_VARIANT=%s\n' "${OTA_IMAGE_VARIANT}" > "$1/etc/armbian-ota-image"
}
