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
    # Stamp into the framework image identity file (written earlier, during
    # rootfs prep; this hook runs at image finalize). Idempotent append.
    local image_release="$1/etc/armbian-image-release"
    if [[ ! -f "${image_release}" ]]; then
        display_alert "OTA runtime" "Missing ${image_release}; cannot stamp IMAGE_VARIANT" "err"
        return 1
    fi
    sed -i '/^IMAGE_VARIANT=/d' "${image_release}"
    printf 'IMAGE_VARIANT=%s\n' "${OTA_IMAGE_VARIANT}" >> "${image_release}"
}
