# Common overlayroot configuration helpers

function ota_set_config_option() {
    local config_file="$1"
    local key="$2"
    local assignment="$3"

    if grep -q "^${key}=" "${config_file}"; then
        sed -i "s|^${key}=.*|${assignment}|" "${config_file}"
    else
        printf '%s\n' "${assignment}" >> "${config_file}"
    fi
}

function ota_overlayroot_device_options() {
    # recurse=0 keeps /boot (and other fstab mounts) as direct mounts: an
    # overlaid /boot would capture runtime writes in the overlay upper and
    # hide them from U-Boot.
    # Both modes reference /dev/armbian-userdata, created by the initramfs
    # 00-seeed-bind-userdata hook on the rootfs disk, dodging the multi-disk
    # duplicate-LABEL udev race.
    if ota_encrypted_rootfs_enabled; then
        printf '%s\n' 'dev=/dev/mapper/armbian-userdata,timeout=30,recurse=0'
    else
        printf '%s\n' 'dev=/dev/armbian-userdata,timeout=30,recurse=0'
    fi
}

function ota_configure_overlayroot() {
    local root_dir="$1"
    local title="$2"
    local device_options="$3"

    display_alert "${title}" "Configuring overlayroot" "info"

    if [[ -f "${root_dir}/etc/initramfs-tools/initramfs.conf" ]]; then
        if ota_set_config_option "${root_dir}/etc/initramfs-tools/initramfs.conf" "BUSYBOX" "BUSYBOX=y"; then
            display_alert "${title}" "Set BUSYBOX=y in initramfs.conf" "info"
        else
            display_alert "${title}" "Failed to set BUSYBOX=y in initramfs.conf" "warn"
        fi
    else
        display_alert "${title}" "initramfs.conf not found" "warn"
    fi

    if [[ -f "${root_dir}/etc/overlayroot.conf" ]]; then
        if ota_set_config_option "${root_dir}/etc/overlayroot.conf" "overlayroot" \
            "overlayroot=\"device:${device_options}\""; then
            display_alert "${title}" "Configured overlayroot backing store" "info"
        else
            display_alert "${title}" "Failed to configure overlayroot backing store" "warn"
        fi
    else
        display_alert "${title}" "overlayroot.conf not found" "warn"
    fi

    if [[ -e "${root_dir}/etc/update-motd.d/97-overlayroot" ]]; then
        rm -f "${root_dir}/etc/update-motd.d/97-overlayroot"
        display_alert "${title}" "Removed overlayroot MOTD mount dump" "info"
    fi
}

# Configure overlayroot before Armbian rebuilds the final initramfs.
function pre_update_initramfs__892_config_overlayroot() {
    ota_configure_overlayroot "${MOUNT}" "OTA" \
        "$(ota_overlayroot_device_options)"
}
