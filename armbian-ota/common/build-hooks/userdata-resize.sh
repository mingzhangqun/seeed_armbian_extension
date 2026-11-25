# Shared userdata resize build hooks

function extension_prepare_config__install_userdata_resize_tools() {
    display_alert "OTA userdata" "Installing userdata resize tools" "info"
    add_packages_to_image util-linux parted e2fsprogs
    if ota_encrypted_rootfs_enabled; then
        add_packages_to_image cryptsetup
    fi
}

function pre_umount_final_image__896_install_resize_userdata_service() {
    display_alert "OTA userdata" "Enabling armbian-resize-userdata service" "info"
    ota_enable_rootfs_service "${MOUNT}" armbian-resize-userdata.service "OTA userdata"
}
