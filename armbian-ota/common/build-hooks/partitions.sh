# Common partition creation and formatting helpers.
#
# Callers own the partition layout and initialize the shared `next`, `p_index`,
# and `script` variables before adding entries.

function ota_require_gpt_partition_table() {
    local title="$1"

    if [[ "${IMAGE_PARTITION_TABLE:-}" != "gpt" ]]; then
        exit_with_error "${title} requires GPT" "IMAGE_PARTITION_TABLE=${IMAGE_PARTITION_TABLE:-unset}"
        return 1
    fi
}

# Raw-FIT boot layout (signed kernel FIT on a raw partition). BOOT_RAW_MODE is
# exported by rk-secure-boot's pre_prepare_partitions__050 hook, but its
# visibility in later hooks is timing-dependent across the host/container
# hook rounds (observed: the same build produced the rescue partition in one
# run and silently dropped it in the next). Re-derive the mode from the same
# inputs rk_autodecrypt_fit_boot_required() uses -- RK_SECURE_UBOOT_ENABLE,
# or auto-decrypt with the OP-TEE bootchain -- so every caller agrees.
# KEEP IN SYNC with rk_secure-disk-encryption/build-hooks/common.sh.
function ota_raw_boot_enabled() {
    if [[ "${BOOT_RAW_MODE:-}" == "yes" ]]; then
        return 0
    fi
    if [[ "${RK_SECURE_UBOOT_ENABLE:-}" == "yes" ]]; then
        return 0
    fi
    if [[ "${CRYPTROOT_ENABLE:-}" == "yes" && "${RK_AUTO_DECRYP:-}" == "yes" && "${RK_OPTEE_BOOT_ENABLE:-}" == "yes" ]]; then
        return 0
    fi
    return 1
}

function ota_install_overlayroot_dependencies() {
    add_packages_to_image overlayroot busybox-static
}

# Partition-size policy
function ota_get_default_partition_sizes() {
    local extra_rootfs_mib="${EXTRA_ROOTFS_MIB_SIZE:-0}"

    [[ "${extra_rootfs_mib}" =~ ^[0-9]+$ ]] ||
        exit_with_error "Invalid EXTRA_ROOTFS_MIB_SIZE" "${extra_rootfs_mib}"


    OTA_BOOT_SIZE=${OTA_BOOT_SIZE:-512}
    OTA_SECURITY_SIZE=${OTA_SECURITY_SIZE:-4}
    # +20% for ext4 metadata and OTA growth; runtime writes go to userdata.
    OTA_ROOTFS_SIZE=${OTA_ROOTFS_SIZE:-$((((rootfs_size + extra_rootfs_mib) * 120 + 99) / 100))}
    # Pre-resize floor; armbian-resize-userdata expands it on first boot.
    OTA_USERDATA_SIZE=${OTA_USERDATA_SIZE:-512}

    [[ "${OTA_BOOT_SIZE}" =~ ^[0-9]+$ && "${OTA_BOOT_SIZE}" -gt 0 ]] ||
        exit_with_error "Invalid OTA_BOOT_SIZE" "${OTA_BOOT_SIZE}"
    [[ "${OTA_SECURITY_SIZE}" =~ ^[0-9]+$ && "${OTA_SECURITY_SIZE}" -gt 0 ]] ||
        exit_with_error "Invalid OTA_SECURITY_SIZE" "${OTA_SECURITY_SIZE}"
    [[ "${OTA_ROOTFS_SIZE}" =~ ^[0-9]+$ && "${OTA_ROOTFS_SIZE}" -gt "${rootfs_size}" ]] ||
        exit_with_error "Invalid OTA_ROOTFS_SIZE" "${OTA_ROOTFS_SIZE}; rootfs requires more than ${rootfs_size} MiB"
    [[ "${OTA_USERDATA_SIZE}" =~ ^[0-9]+$ && "${OTA_USERDATA_SIZE}" -gt 0 ]] ||
        exit_with_error "Invalid OTA_USERDATA_SIZE" "${OTA_USERDATA_SIZE}"

    display_alert "OTA partitions" "Using boot=${OTA_BOOT_SIZE} MiB, security=${OTA_SECURITY_SIZE} MiB, rootfs=${OTA_ROOTFS_SIZE} MiB, userdata=${OTA_USERDATA_SIZE} MiB" "info"
}

# Partition-table construction
function ota_partition_append() {
    local index_var="$1"
    local name="$2"
    local size="$3"
    local type="$4"
    local attrs="${5:-}"

    printf -v "${index_var}" '%s' "${p_index}"
    script+="${p_index} : name=\"${name}\", start=${next}MiB, size=${size}MiB, type=${type}"
    if [[ -n "${attrs}" ]]; then
        script+=", attrs=\"${attrs}\""
    fi
    script+="\\n"
    next=$((next + size))
    p_index=$((p_index + 1))
}

# Filesystem formatting
function ota_partition_format_ext4() {
    local title="$1"
    local dev="$2"
    local label="$3"
    local description="$4"

    check_loop_device "${dev}"
    display_alert "${title}" "Formatting ${description} (${dev}) as ext4 with label ${label}" "info"
    run_host_command_logged mkfs.ext4 -q -L "${label}" "${dev}" ||
        exit_with_error "Failed to format ${description} as ext4" "${dev}"
}

function ota_partition_format_luks_ext4() {
    local title="$1"
    local dev="$2"
    local mapper_name="$3"
    local label="$4"
    local description="$5"
    local mapper_dev="/dev/mapper/${mapper_name}"

    check_loop_device "${dev}"
    [[ -n "${CRYPTROOT_PASSPHRASE}" ]] ||
        exit_with_error "CRYPTROOT_PASSPHRASE is required for encrypted ${description}"
    command -v cryptsetup >/dev/null 2>&1 ||
        exit_with_error "cryptsetup not found while formatting encrypted ${description}" "host dependency missing"

    display_alert "${title}" "Formatting ${description} (${dev}) as LUKS + ext4(label=${label})" "info"
    printf '%s' "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksFormat ${CRYPTROOT_PARAMETERS} "${dev}" - ||
        exit_with_error "Failed to luksFormat ${description}" "${dev}"
    printf '%s' "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksOpen "${dev}" "${mapper_name}" - ||
        exit_with_error "Failed to unlock encrypted ${description}" "${dev}"
    run_host_command_logged mkfs.ext4 -q -L "${label}" "${mapper_dev}" || {
        run_host_command_logged cryptsetup luksClose "${mapper_name}" || true
        exit_with_error "Failed to format encrypted ${description}" "${mapper_dev}"
    }
    run_host_command_logged cryptsetup luksClose "${mapper_name}" ||
        exit_with_error "Failed to close encrypted ${description}" "${mapper_dev}"
}
