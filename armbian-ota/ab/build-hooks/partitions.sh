# A/B partition layout and policy

function extension_prepare_config__install_overlayroot_userdata() {
    display_alert "A/B partition OTA" "install overlayroot, busybox-static, libubootenv-tool and zstd" "info"
    ota_install_overlayroot_dependencies
    # Mirror zstd, else zst packages are refused on A/B devices.
    add_packages_to_image libubootenv-tool zstd
}

function pre_prepare_partitions__ab_part_ota() {
    ota_require_gpt_partition_table "A/B partition OTA" || return 1

    USE_HOOK_FOR_PARTITION="yes"
    BOOTFS_TYPE="ext4"
    BOOT_FS_LABEL="armbi_boota"
    ROOTFS_TYPE="ext4"
    ROOT_FS_LABEL="armbi_roota"
    if ota_encrypted_rootfs_enabled; then
        display_alert "A/B partition OTA" "Creating A/B encrypted partitions: boot_a, boot_b, security, rootfs_a, rootfs_b, userdata" "info"
    else
        display_alert "A/B partition OTA" "Creating A/B partitions: boot_a, boot_b, rootfs_a, rootfs_b, userdata" "info"
    fi
}

function prepare_image_size__ab_part_ota() {
    local security_size=0
    ota_get_default_partition_sizes
    ota_encrypted_rootfs_enabled && security_size=${OTA_SECURITY_SIZE}

    FIXED_IMAGE_SIZE=$((OFFSET + (OTA_BOOT_SIZE * 2) + security_size + (OTA_ROOTFS_SIZE * 2) + OTA_USERDATA_SIZE))
    display_alert "A/B partition OTA" "Setting FIXED_IMAGE_SIZE to ${FIXED_IMAGE_SIZE} MiB for equal rootfs_a and rootfs_b" "info"
}

function create_partition_table__ab_part_ota() {
    local next=${OFFSET}
    local p_index=1
    local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
    script+="table-length: ${AB_GPT_TABLE_LENGTH:-64}\n"

    local data_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
    if ota_raw_boot_enabled; then
        boot_type=${data_type}
    fi
    local boot_a_index boot_b_index rootfs_a_index rootfs_b_index userdata_index
    # U-Boot's default distro scan only considers GPT partitions with the
    # LegacyBIOSBootable attribute. Mark filesystem boot_a as the deterministic
    # fallback when the persistent environment is absent or invalid. A valid
    # A/B environment selects either slot explicitly.
    if ota_raw_boot_enabled; then
        ota_partition_append boot_a_index "boot_a" "${OTA_BOOT_SIZE}" "${boot_type}"
    else
        ota_partition_append boot_a_index "boot_a" "${OTA_BOOT_SIZE}" "${boot_type}" "LegacyBIOSBootable"
    fi
    ota_partition_append boot_b_index "boot_b" "${OTA_BOOT_SIZE}" "${boot_type}"

    local security_index=""
    if ota_encrypted_rootfs_enabled; then
        ota_partition_append security_index "security" "${OTA_SECURITY_SIZE}" "${data_type}"
    fi

    local root_type="${PARTITION_TYPE_UUID_ROOT:-${data_type}}"
    ota_partition_append rootfs_a_index "rootfs_a" "${OTA_ROOTFS_SIZE}" "${root_type}"
    ota_partition_append rootfs_b_index "rootfs_b" "${OTA_ROOTFS_SIZE}" "${root_type}"
    ota_partition_append userdata_index "userdata" "${OTA_USERDATA_SIZE}" "${root_type}"

    display_alert "A/B partition OTA" "Custom A/B partition table:\n${script}" "debug"
    printf "%b" "${script}" | run_host_command_logged sfdisk "${SDCARD}.raw" ||
        exit_with_error "A/B partition creation failed" "sfdisk"

    AB_BOOT_A_PART_INDEX=${boot_a_index}
    AB_BOOT_B_PART_INDEX=${boot_b_index}
    AB_ROOTFS_A_PART_INDEX=${rootfs_a_index}
    AB_ROOTFS_B_PART_INDEX=${rootfs_b_index}
    if [[ -n "${security_index}" ]]; then
        AB_SECURITY_PART_INDEX=${security_index}
        SECURE_STORAGE_SECURITY_PART_INDEX=${security_index}
    fi
    bootpart=${boot_a_index}
    rootpart=${rootfs_a_index}
    AB_USERDATA_PART_INDEX=${userdata_index}
}

function format_partitions__ab_part_ota() {
    if [[ -n "${AB_BOOT_B_PART_INDEX}" ]]; then
        local boot_b_dev="${LOOP}p${AB_BOOT_B_PART_INDEX}"
        if ota_raw_boot_enabled; then
            display_alert "A/B partition OTA" "Secure FIT mode: leaving boot_b as raw partition" "info"
        else
            ota_partition_format_ext4 "A/B partition OTA" "${boot_b_dev}" "armbi_bootb" "boot_b"
        fi
    fi

    if [[ -n "${AB_ROOTFS_B_PART_INDEX}" ]]; then
        local rootfs_b_dev="${LOOP}p${AB_ROOTFS_B_PART_INDEX}"
        if ota_encrypted_rootfs_enabled; then
            ota_partition_format_luks_ext4 "A/B partition OTA" "${rootfs_b_dev}" "armbian-rootb-build" "armbi_rootb" "rootfs_b"
        else
            ota_partition_format_ext4 "A/B partition OTA" "${rootfs_b_dev}" "armbi_rootb" "rootfs_b"
        fi
    fi

    if [[ -n "${AB_USERDATA_PART_INDEX}" ]]; then
        local userdata_dev="${LOOP}p${AB_USERDATA_PART_INDEX}"
        if ota_encrypted_rootfs_enabled; then
            ota_partition_format_luks_ext4 "A/B partition OTA" "${userdata_dev}" \
                "armbian-ab-userdata-build" "armbi_usrdata" "userdata"
        else
            ota_partition_format_ext4 "A/B partition OTA" "${userdata_dev}" "armbi_usrdata" "userdata"
        fi
    fi
}
