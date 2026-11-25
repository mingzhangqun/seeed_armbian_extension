# Common OTA installation helpers: rootfs runtime, services, initramfs
# pieces, and the checked single-file install shared by every list.

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
        display_alert "OTA runtime" "Missing ${image_release}; cannot stamp image identity" "err"
        return 1
    fi
    sed -i '/^IMAGE_VARIANT=/d;/^RELEASE=/d' "${image_release}"
    printf 'IMAGE_VARIANT=%s\n' "${OTA_IMAGE_VARIANT}" >> "${image_release}"
    # Build-time truth for the release gate: stamped images never infer the
    # suite from distro files at runtime.
    printf 'RELEASE=%s\n' "${RELEASE}" >> "${image_release}"
}

# Install one file into the image, failing the build on a missing source.
function ota_install_file_checked() {
    local title="$1" source="$2" destination="$3" mode="$4"

    [[ -f "${source}" ]] || {
        display_alert "${title}" "Missing source file: ${source}" "err"
        return 1
    }
    install -D -m "${mode}" "${source}" "${destination}" || {
        display_alert "${title}" "Failed to install: ${source}" "err"
        return 1
    }
}

# Install "src:dst:mode" entries from source_dir into root_dir.
function ota_install_file_list() {
    local title="$1" source_dir="$2" root_dir="$3"
    shift 3
    local entry source_path destination_path mode

    for entry in "$@"; do
        IFS=: read -r source_path destination_path mode <<< "${entry}"
        ota_install_file_checked "${title}" "${source_dir}/${source_path}" \
            "${root_dir}/${destination_path}" "${mode}" || return 1
    done
}

# Enable a rootfs service; failure warns, never fails the build.
function ota_enable_rootfs_service() {
    local root_dir="$1" service="$2" title="$3"

    chroot "${root_dir}" systemctl enable "${service}" ||
        display_alert "${title}" "Failed to enable ${service}" "warn"
}

# Initramfs pieces every flavor installs: the userdata resolver anchors
# userdata (and /boot where present) to the rootfs disk, so multi-disk
# clones never put root-rw on the wrong disk. Extra entries append.
function ota_install_common_initramfs() {
    local root_dir="$1"
    shift
    local title="Seeed OTA common initramfs"
    local -a entries=(
        "hooks/98-seeed-bind-userdata:etc/initramfs-tools/hooks/98-seeed-bind-userdata:0755"
        "scripts/init-bottom/00-seeed-bind-userdata:etc/initramfs-tools/scripts/init-bottom/00-seeed-bind-userdata:0755"
    )

    display_alert "${title}" "Installing userdata resolver" "info"
    ota_install_file_list "${title}" "${OTA_COMMON_INITRAMFS}" "${root_dir}" \
        "${entries[@]}" "$@" || return 1
}
