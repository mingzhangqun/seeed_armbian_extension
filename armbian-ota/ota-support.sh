#
# Armbian OTA build extension entry point.
#
# Keep this file as the stable Armbian extension path. Implementation is split
# by common, A/B, and Recovery ownership; hook function names remain unchanged.
#

OTA_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OTA_COMMON_ROOTFS="${OTA_SUPPORT_DIR}/common/rootfs"
readonly OTA_RECOVERY_ROOTFS="${OTA_SUPPORT_DIR}/recovery/rootfs"
readonly OTA_RECOVERY_INITRAMFS="${OTA_SUPPORT_DIR}/recovery/initramfs"
readonly OTA_AB_ROOTFS="${OTA_SUPPORT_DIR}/ab/rootfs"

function ota_encrypted_rootfs_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function ota_secure_boot_encrypted_rootfs_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]] && ota_encrypted_rootfs_enabled
}

if [[ "${OTA_ENABLE:-}" == "yes" ]]; then
    for ota_support_module in \
        common/build-hooks/image-naming \
        common/build-hooks/partitions \
        common/build-hooks/rootfs-install \
        common/build-hooks/overlayroot \
        common/build-hooks/userdata-resize \
        common/build-hooks/ota-payload-security \
        common/build-hooks/uboot-env-prefill
    do
        # shellcheck source=/dev/null
        source "${OTA_SUPPORT_DIR}/${ota_support_module}.sh"
    done

    if [[ "${AB_PART_OTA:-}" == "yes" ]]; then
        for ota_support_module in \
            ab/build-hooks/partitions \
            ab/build-hooks/runtime-install
        do
            # shellcheck source=/dev/null
            source "${OTA_SUPPORT_DIR}/${ota_support_module}.sh"
        done
    else
        for ota_support_module in \
            recovery/build-hooks/partitions \
            recovery/build-hooks/runtime-install \
            recovery/build-hooks/rescue-artifacts
        do
            # shellcheck source=/dev/null
            source "${OTA_SUPPORT_DIR}/${ota_support_module}.sh"
        done
    fi

    # shellcheck source=/dev/null
    source "${OTA_SUPPORT_DIR}/common/build-hooks/package-create.sh"
fi

unset ota_support_module
