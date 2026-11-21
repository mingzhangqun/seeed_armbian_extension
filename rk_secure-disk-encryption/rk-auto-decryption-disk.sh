#
# Shared Helpers And Auto-decryption Modules
#

rk_autodecrypt_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${rk_autodecrypt_dir}/build-hooks/common.sh"
source "${rk_autodecrypt_dir}/build-hooks/auto-decryption.sh"

unset rk_autodecrypt_dir

#
# U-Boot Hooks
#

function build_custom_uboot__100_autodecrypt_prepare_defconfig() {
    if ! rk_autodecrypt_nonsecure_mode_enabled || [[ "${RK_OPTEE_BOOT_ENABLE}" != "yes" ]]; then
        return 0
    fi

    rk_autodecrypt_install_patch_uboot_target_wrapper
}

#
# Initramfs Hooks
#

function pre_update_initramfs__300_optee_inject() {
    local root_dir="${MOUNT}"

    rk_autodecrypt_ensure_sdk_tools
    rk_autodecrypt_ensure_pycryptodome

    [[ -d "${root_dir}" ]] || {
        display_alert "optee" "root_dir does not exist: ${root_dir}" "err"
        return 1
    }

    rk_autodecrypt_install_optee_client "${root_dir}" "${RK_AUTODECRYPT_SDK_TOOLS}" || return 1
    rk_autodecrypt_build_and_install_tee_user "${root_dir}" "${RK_AUTODECRYPT_SDK_TOOLS}" || return 1
    display_alert "optee" "OP-TEE client installation completed" "info"
    rk_autodecrypt_install_initramfs_hooks "${root_dir}" || return 1
}

#
# Partition Hooks
#

function pre_prepare_partitions__secure_storage_partitions() {
    rk_secure_storage_prepare_partitions
}

function create_partition_table__secure_storage() {
    rk_secure_storage_create_partition_table
}

function prepare_image_size__secure_storage_partitions() {
    rk_secure_storage_prepare_image_size
}

function post_create_partitions__920_verify_secure_storage_layout() {
    rk_secure_storage_verify_layout
}

function format_partitions__secure_storage() {
    rk_secure_storage_format_partitions
}
