# Recovery partition layout and policy

function extension_prepare_config__install_recovery_ota() {
    ota_install_overlayroot_dependencies
    # v0.8: zstd packs/unpacks the lazy backup and the OTA payloads.
    # fw_setenv/fw_printenv come from the Debian bookworm libubootenv-tool
    # debs installed by ota_install_recovery_fw_env_tools (runtime-install.sh):
    # Ubuntu noble's u-boot-tools ships no fw_* binaries and uboot-envtools
    # has no arm64 installation candidate on ports.ubuntu.com.
    add_packages_to_image zstd
}

function pre_prepare_partitions__recovery_ota() {
    ota_require_gpt_partition_table "Recovery OTA" || return 1

    USE_HOOK_FOR_PARTITION="yes"
    ROOTFS_TYPE="ext4"
    ROOT_FS_LABEL="armbi_root"

    # Recovery images always carry a dedicated /boot partition so that U-Boot
    # reads boot files (armbianEnv.txt, Image, uInitrd, dtb) directly from a
    # plain ext4 partition instead of the overlayfs-backed rootfs lower layer.
    # At runtime the boot partition is mounted on top of overlayfs via fstab,
    # which makes runtime /boot writes (apt kernel upgrades, manual tweaks,
    # armbian-ota tooling) visible to U-Boot on the next boot.
    #
    # Raw boot mode (secure boot, BOOT_RAW_MODE=yes) keeps using a raw FIT
    # partition; rk-secure-boot.sh clears `bootpart` after partition creation
    # so Armbian's standard mkfs/mount path is skipped for it.
    if ! ota_raw_boot_enabled; then
        BOOTPART_REQUIRED="yes"
        BOOTFS_TYPE="ext4"
        BOOT_FS_LABEL="armbi_boot"
        # Boot size precedence: OTA_BOOT_SIZE > BOOTSIZE > 512. OTA_BOOT_SIZE
        # is only computed later (ota_get_default_partition_sizes needs
        # rootfs_size), so only an explicit env value is visible here; the
        # inline 512 keeps Armbian core from filling its own 256 MiB default.
        # Keep in sync with ota_get_default_partition_sizes().
        BOOTSIZE="${OTA_BOOT_SIZE:-${BOOTSIZE:-512}}"
    fi

    if ota_encrypted_rootfs_enabled; then
        display_alert "Recovery OTA" "Creating security, encrypted rootfs and userdata partitions" "info"
    else
        display_alert "Recovery OTA" "Creating rootfs and userdata partitions" "info"
    fi
}

function prepare_image_size__recovery_ota() {
    local boot_size=0
    local security_size=0

    ota_get_default_partition_sizes
    ota_encrypted_rootfs_enabled && security_size=${OTA_SECURITY_SIZE}
    # Recovery always reserves space for a boot partition (ext4 for plain /
    # auto-decrypt modes, raw FIT for secure boot).
    boot_size=${BOOTSIZE:-${OTA_BOOT_SIZE}}

    FIXED_IMAGE_SIZE=$((OFFSET + boot_size + security_size + OTA_ROOTFS_SIZE + OTA_USERDATA_SIZE))
    display_alert "Recovery OTA" "Setting FIXED_IMAGE_SIZE=${FIXED_IMAGE_SIZE} MiB (boot=${boot_size} MiB, rootfs=${OTA_ROOTFS_SIZE} MiB, userdata=${OTA_USERDATA_SIZE} MiB)" "info"
}

function create_partition_table__recovery_ota() {
    local next=${OFFSET}
    local p_index=1
    local boot_index rootfs_index userdata_index security_index
    local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
    local data_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    script+="table-length: ${RECOVERY_GPT_TABLE_LENGTH:-64}\n"

    # Boot partition always leads the table. For BOOT_RAW_MODE=yes (secure
    # boot) it carries the raw FIT image; otherwise Armbian's standard boot
    # partition handling (partitioning.sh) formats it as ext4 with label
    # armbi_boot and mounts it at $MOUNT/boot.
    ota_partition_append boot_index "boot" "${BOOTSIZE:-${OTA_BOOT_SIZE}}" "${data_type}"
    bootpart=${boot_index}

    if ota_encrypted_rootfs_enabled; then
        ota_partition_append security_index "security" "${OTA_SECURITY_SIZE}" "${data_type}"
    fi

    local root_type="${PARTITION_TYPE_UUID_ROOT:-${data_type}}"
    ota_partition_append rootfs_index "rootfs" "${OTA_ROOTFS_SIZE}" "${root_type}"
    ota_partition_append userdata_index "userdata" "${OTA_USERDATA_SIZE}" "${root_type}"

    display_alert "Recovery OTA" "Custom recovery partition table:\n${script}" "debug"
    printf "%b" "${script}" | run_host_command_logged sfdisk "${SDCARD}.raw" ||
        exit_with_error "Recovery userdata partition creation failed" "${SDCARD}"

    rootpart=${rootfs_index}
    RECOVERY_USERDATA_PART_INDEX=${userdata_index}
    if [[ -n "${security_index:-}" ]]; then
        SECURE_STORAGE_SECURITY_PART_INDEX=${security_index}
    fi
}

function format_partitions__recovery_ota() {
    if [[ -z "${RECOVERY_USERDATA_PART_INDEX:-}" ]]; then
        return 0
    fi

    local userdata_dev="${LOOP}p${RECOVERY_USERDATA_PART_INDEX}"
    if ota_encrypted_rootfs_enabled; then
        ota_partition_format_luks_ext4 "Recovery OTA" "${userdata_dev}" \
            "armbian-recovery-userdata-build" "armbi_usrdata" "userdata"
    else
        ota_partition_format_ext4 "Recovery OTA" "${userdata_dev}" "armbi_usrdata" "userdata"
    fi
}
