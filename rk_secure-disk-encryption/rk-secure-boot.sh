#
# Shared Helpers And Secure Boot Modules
#

rk_secure_boot_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${rk_secure_boot_dir}/build-hooks/common.sh"
source "${rk_secure_boot_dir}/build-hooks/uboot-package-name.sh"
source "${rk_secure_boot_dir}/build-hooks/secure-boot-uboot.sh"
source "${rk_secure_boot_dir}/build-hooks/secure-boot-image.sh"

unset rk_secure_boot_dir

#
# Source Fetchers
#

function fetch_sources_tools__rksdk_tools() {
    rk_fetch_sdk_tools
}

#
# U-Boot Hooks
#

function pre_config_uboot_target__rk_secure_boot_prepare() {
    rk_secure_boot_prepare_uboot_tree
}

function post_config_uboot_target__rk_secure_boot_stage_fit_generator() {
    if [[ "${RK_SECURE_UBOOT_ENABLE:-no}" != "yes" && "${RK_OPTEE_BOOT_ENABLE:-no}" != "yes" ]]; then
        return 0
    fi

    local fragment

    rk_secure_boot_stage_uboot_fit_generator "$(pwd)"

    if rk_full_secure_boot_enabled; then
        fragment="$(rk_secure_uboot_config_fragment_path)" ||
            exit_with_error "No secure U-Boot config fragment mapping found" "BOOT_SOC=${BOOT_SOC:-} BOARD_NAME=${BOARD_NAME:-${BOARD:-}}"
        rk_secure_boot_apply_config_fragment "${fragment}"
    fi
}

function post_uboot_custom_postprocess__rk_secure_boot_sign_fit() {
    rk_secure_boot_sign_uboot_fit
}

function check_uboot_produced_binary_file__rk_secure_boot_fit() {
    rk_secure_boot_check_produced_fit_image
}

function extension_finish_config__rk_secure_bootconfig() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    local fragment its_template
    fragment="$(rk_secure_uboot_config_fragment_path)" ||
        exit_with_error "Secure U-Boot config fragment missing" "BOOT_SOC=${BOOT_SOC:-} BOARD_NAME=${BOARD_NAME:-${BOARD:-}}"

    its_template="$(resolve_platform_its_template)"
    if [[ -z "${its_template}" ]]; then
        exit_with_error "Secure kernel FIT ITS template missing" "$(rk_resolve_extension_dir "u-boot/fit-kernel")/u-boot/fit-kernel"
    fi

    display_alert "secure-uboot" "Using base U-Boot defconfig plus secure fragment: ${fragment}" "info"
}

#
# Kernel And Partition Hooks
#

function pre_install_kernel_debs__300_disable_kernel_root_symlinks_for_raw_fit() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    rk_secure_boot_disable_kernel_root_symlinks "${SDCARD}"
}

function pre_prepare_partitions__040_require_secure_storage_hook() {
    # If secure boot + auto decrypt are enabled together, secure storage hook must be present.
    if [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        if [[ "$(type -t create_partition_table__secure_storage || true)" != "function" ]]; then
            exit_with_error "rk-auto-decryption secure storage partition hook is missing" "create_partition_table__secure_storage not found"
        fi
    fi
}

function pre_prepare_partitions__050_set_raw_boot_partition() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    display_alert "secure-uboot" "Enabling RAW boot partition mode" "info"

    BOOTPART_REQUIRED="yes"

    # Same boot size precedence as the recovery/A-B layouts:
    # OTA_BOOT_SIZE > BOOTSIZE > 512.
    export BOOTSIZE="${OTA_BOOT_SIZE:-${BOOTSIZE:-512}}"
    display_alert "secure-uboot" "Forcing boot partition size: ${BOOTSIZE} MiB" "info"

    # Disable standard boot filesystem handling
    export BOOT_RAW_MODE="yes"
}

function pre_prepare_partitions__change_boot_partition_name() {
    rk_secure_boot_apply_boot_partition_label
}

function post_create_partitions__handle_raw_boot() {
    rk_secure_boot_capture_raw_boot_partition
}

function pre_package_kernel_image__create_resource_img() {
    rk_secure_boot_create_resource_img
}

function pre_umount_final_image__package_fit() {
    rk_secure_boot_package_final_fit
}

function post_umount_final_image__flash_fit_kernel() {
    rk_secure_boot_flash_fit_kernel
}
