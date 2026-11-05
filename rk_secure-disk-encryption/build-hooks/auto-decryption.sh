# Auto-decryption build hook helpers
function rk_autodecrypt_detect_vendor_board() {
    if [[ -n "${UBOOT_VENDOR_BOARD}" ]]; then
        echo "${UBOOT_VENDOR_BOARD}"
        return 0
    fi

    local detected_board
    detected_board="$(rk_detect_vendor_board)"
    if [[ -n "${detected_board}" && "${detected_board}" != "unknown" ]]; then
        echo "${detected_board}"
        return 0
    fi

    echo "unknown"
}

function rk_autodecrypt_apply_secure_fragment_to_defconfig() {
    local target_defconfig="$1"
    local fragment

    [[ -f "${target_defconfig}" ]] || return 1

    fragment="$(rk_secure_uboot_config_fragment_path)" || return 1
    rk_apply_kconfig_fragment scripts/config "${fragment}" --file "${target_defconfig}" || return 1
    display_alert "optee-autodecrypt" "Applied secure config fragment to ${target_defconfig}: ${fragment}" "info"
}

function rk_autodecrypt_prepare_defconfig_for_current_tree() {
    local vendor_board target_defconfig
    vendor_board="$(rk_autodecrypt_detect_vendor_board)"
    target_defconfig="configs/${vendor_board}_defconfig"

    rk_autodecrypt_apply_secure_fragment_to_defconfig "${target_defconfig}" ||
        exit_with_error "auto-decrypt secure config fragment apply failed" "vendor_board=${vendor_board} target=${target_defconfig}"
}

function rk_autodecrypt_install_patch_uboot_target_wrapper() {
    if [[ "$(type -t patch_uboot_target || true)" != "function" ]]; then
        display_alert "optee-autodecrypt" "patch_uboot_target not found, cannot install post-patch defconfig hook" "warn"
        return 0
    fi

    if [[ "$(type -t __rk_autodecrypt_patch_uboot_target_original || true)" == "function" ]]; then
        return 0
    fi

    eval "$(declare -f patch_uboot_target | sed '1s/^patch_uboot_target/__rk_autodecrypt_patch_uboot_target_original/')"
    patch_uboot_target() {
        __rk_autodecrypt_patch_uboot_target_original "$@" || return $?

        if rk_autodecrypt_nonsecure_mode_enabled && [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
            rk_autodecrypt_prepare_defconfig_for_current_tree
        fi
    }

    display_alert "optee-autodecrypt" "Installed post-patch defconfig hook wrapper on patch_uboot_target" "info"
}
function rk_autodecrypt_ensure_sdk_tools() {
    RK_AUTODECRYPT_SDK_TOOLS="$(rk_sdk_tools_root)"
    rk_ensure_sdk_tools "optee"
}

function rk_autodecrypt_ensure_pycryptodome() {
	# rk_tee_user/v2 signing scripts try the Cryptodome namespace first and
	# fall back to Crypto. Debian's python3-pycryptodome ships Cryptodome only.
	if python3 - <<'PY' >/dev/null 2>&1
try:
	import Cryptodome
except ImportError:
	import Crypto
PY
	then
		return 0
	fi

	# The build container ships without apt lists (pruned when the image is
	# baked); refresh them or install fails with "Unable to locate package".
	rk_run_host_command apt-get update ||
		display_alert "optee" "apt-get update failed, trying install with existing lists" "warn"
	rk_run_host_command apt-get install -y python3-pycryptodome ||
		exit_with_error "failed to install python3-pycryptodome" "apt-get"

	python3 - <<'PY' || exit_with_error "pycryptodome not importable after install" "python3"
try:
	import Cryptodome
except ImportError:
	import Crypto
PY
}
function rk_autodecrypt_install_optee_client() {
    local root_dir="$1"
    local sdk_tools="$2"
    local optee_bin_dir="${sdk_tools}/external/security/bin/optee_v2/lib/arm64"

    display_alert "optee" "Installing OP-TEE client from library" "info"
    if [[ ! -d "${optee_bin_dir}" ]]; then
        display_alert "optee" "OP-TEE client binary directory not found: ${optee_bin_dir}" "err"
        return 1
    fi

    mkdir -p "${root_dir}/usr/bin" "${root_dir}/usr/lib" ||
        exit_with_error "Failed to create OP-TEE client directories" "${root_dir}"

    install -m 0755 "${optee_bin_dir}/tee-supplicant" "${root_dir}/usr/bin/tee-supplicant" ||
        exit_with_error "Failed to install tee-supplicant" "${optee_bin_dir}/tee-supplicant"

    local lib
    for lib in libteec.so libteec.so.1 libteec.so.1.0 libteec.so.1.0.0; do
        install -m 0644 "${optee_bin_dir}/${lib}" "${root_dir}/usr/lib/${lib}" ||
            exit_with_error "Failed to install ${lib}" "${optee_bin_dir}/${lib}"
    done
}

function rk_autodecrypt_resolve_tee_toolchains() {
	# build.sh's own discovery expects prebuilt toolchain dirs the sdk-tools
	# repo does not ship, and its check_toolchain_* bail out with status 0
	# (silent no-op build). Resolve host cross-toolchain prefixes instead and
	# pass them through the env vars build.sh honors.
	if [[ -n "${AARCH64_TOOLCHAIN:-}" && -n "${ARM32_TOOLCHAIN:-}" ]]; then
		return 0
	fi

	local aarch64_gcc arm32_gcc
	aarch64_gcc="$(type -P aarch64-none-linux-gnu-gcc || type -P aarch64-linux-gnu-gcc || true)"
	arm32_gcc="$(type -P arm-none-linux-gnueabihf-gcc || type -P arm-linux-gnueabihf-gcc || true)"
	if [[ -z "${aarch64_gcc}" || -z "${arm32_gcc}" ]]; then
		return 1
	fi

	# type -P walks PATH; on ccache-enabled runners the first hit is the
	# /usr/lib/ccache/ symlink dir, which only ships compiler aliases. The
	# TA build also needs <triple>-objcopy/ld/etc, so strip any ccache
	# wrapper dir and prefer the real toolchain bin/ from PATH order.
	local candidate
	for candidate in "${aarch64_gcc}" "/usr/bin/aarch64-linux-gnu-gcc"; do
		[[ -x "${candidate}" && "${candidate}" != */ccache/* ]] || continue
		aarch64_gcc="${candidate}"
		break
	done
	for candidate in "${arm32_gcc}" "/usr/bin/arm-linux-gnueabihf-gcc"; do
		[[ -x "${candidate}" && "${candidate}" != */ccache/* ]] || continue
		arm32_gcc="${candidate}"
		break
	done

	if [[ "${aarch64_gcc}" == */ccache/* || "${arm32_gcc}" == */ccache/* ]]; then
		display_alert "optee" "toolchain resolved under /usr/lib/ccache, missing objcopy/ld for TA build" "err"
		return 1
	fi

	export AARCH64_TOOLCHAIN="${aarch64_gcc%gcc}"
	export ARM32_TOOLCHAIN="${arm32_gcc%gcc}"
	display_alert "optee" "rk_tee_user toolchains: aarch64=${AARCH64_TOOLCHAIN} arm32=${ARM32_TOOLCHAIN}" "info"
}

# Patches under patches/rk_tee_user/ keep the sdk-tools TA dev-kit buildable
# with the Debian toolchains resolved above. Restoring the tracked targets
# first makes the step idempotent and allows the patch files to be updated
# freely: whatever was applied last time is dropped and the current patch
# set is applied on the pristine files.
function rk_autodecrypt_apply_tee_user_patches() {
    local sdk_tools="$1"
    local patch_file

    patch_file="$(rk_resolve_extension_dir "patches/rk_tee_user")/patches/rk_tee_user/0001-ta-link-force-sysv-hash-style.patch"
    [[ -f "${patch_file}" ]] || exit_with_error "rk_tee_user patch file missing" "${patch_file}"

    git -C "${sdk_tools}" checkout -- \
        external/security/rk_tee_user/v2/export-ta_arm32/mk/link.mk \
        external/security/rk_tee_user/v2/export-ta_arm64/mk/link.mk 2>/dev/null || true

    git -C "${sdk_tools}" apply "${patch_file}" ||
        exit_with_error "failed to apply rk_tee_user patch" "${patch_file}"

    display_alert "optee" "Applied rk_tee_user patches (TA sysv hash style)" "info"
}

function rk_autodecrypt_build_and_install_tee_user() {
    local root_dir="$1"
    local sdk_tools="$2"
    local rk_tee_build_dir="${sdk_tools}/external/security/rk_tee_user/v2"
    local keybox_app_path ta_file_path

    display_alert "optee" "Starting compilation of rk_tee_user_v2" "info"
    if [[ ! -d "${rk_tee_build_dir}" ]]; then
        display_alert "optee" "rk_tee_user_v2 source directory not found: ${rk_tee_build_dir}" "err"
        return 1
    fi

    (
        cd "${rk_tee_build_dir}" || exit 1
        rk_autodecrypt_resolve_tee_toolchains ||
            exit_with_error "no aarch64/arm32 cross toolchains found for rk_tee_user_v2 build"
        rk_autodecrypt_apply_tee_user_patches "${sdk_tools}"
        ./build.sh 6432
    ) || {
        display_alert "optee" "rk_tee_user_v2 compilation failed" "err"
        return 1
    }

    keybox_app_path="${rk_tee_build_dir}/out/extra_app/keybox_app"
    ta_file_path="${rk_tee_build_dir}/out/ta/extra_app/8c6cf810-685d-4654-ae71-8031beee467e.ta"
    [[ -f "${keybox_app_path}" ]] || exit_with_error "keybox_app not found after build" "${keybox_app_path}"
    [[ -f "${ta_file_path}" ]] || exit_with_error "TA file not found after build" "${ta_file_path}"

    mkdir -p "${root_dir}/lib/optee_armtz" ||
        exit_with_error "Failed to create optee_armtz" "${root_dir}/lib/optee_armtz"
    install -m 0755 "${keybox_app_path}" "${root_dir}/usr/bin/keybox_app" ||
        exit_with_error "Failed to install keybox_app" "${keybox_app_path}"
    install -m 0644 "${ta_file_path}" "${root_dir}/lib/optee_armtz/8c6cf810-685d-4654-ae71-8031beee467e.ta" ||
        exit_with_error "Failed to install OP-TEE TA" "${ta_file_path}"

    display_alert "optee" "rk_tee_user_v2 compiled and installed successfully" "info"
}

function rk_autodecrypt_install_initramfs_file() {
    local src="$1"
    local dst="$2"
    local label="$3"

    local dst_dir
    dst_dir="$(dirname "${dst}")"

    mkdir -p "${dst_dir}" ||
        exit_with_error "Failed to create initramfs directory" "${dst_dir}"

    [[ -f "${src}" ]] || exit_with_error "${label} source file not found" "${src}"
    cp "${src}" "${dst}" || {
        display_alert "optee" "Failed to copy ${label}" "err"
        return 1
    }
    chmod +x "${dst}" || return 1
    display_alert "optee" "${label} installation completed" "info"
}

function rk_autodecrypt_install_initramfs_hooks() {
    local root_dir="$1"
    local extension_dir
    extension_dir="$(rk_resolve_extension_dir "initramfs")"

    display_alert "optee" "Installing install-optee initramfs hook" "info"
    rk_autodecrypt_install_initramfs_file \
        "${extension_dir}/initramfs/install-optee" \
        "${root_dir}/etc/initramfs-tools/hooks/install-optee" \
        "install-optee hook" || return 1

    display_alert "optee" "Installing decryption-disk script" "info"
    rk_autodecrypt_install_initramfs_file \
        "${extension_dir}/initramfs/decryption-disk.sh" \
        "${root_dir}/etc/initramfs-tools/scripts/init-top/0-decryption-disk" \
        "decryption-disk script" || return 1
}
function rk_secure_storage_format_partition() {
    local sec_dev="$1"

    if [[ "${SECURE_STORAGE_SECURITY_FS_TYPE}" == "none" ]]; then
        return 0
    fi

    display_alert "secure-storage" "mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} on security (${sec_dev})" "info"
    if command -v mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} >/dev/null 2>&1; then
        mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} -q "${sec_dev}" || {
            display_alert "secure-storage" "security mkfs failed" "err"
            return 1
        }
    else
        display_alert "secure-storage" "mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} not found" "err"
        return 1
    fi
}

function rk_secure_storage_write_passphrase() {
    local sec_dev="$1"
    local read_back

    if [[ "${CRYPTROOT_ENABLE}" != "yes" || -z "${CRYPTROOT_PASSPHRASE}" ]]; then
        return 0
    fi

    display_alert "secure-storage" "Writing CRYPTROOT_PASSPHRASE to security partition" "info"
    wait_for_disk_sync "before writing to security partition"

    printf "%s" "${CRYPTROOT_PASSPHRASE}" | dd of="${sec_dev}" bs=1 count="${#CRYPTROOT_PASSPHRASE}" conv=fsync 2>/dev/null || {
        display_alert "secure-storage" "Failed to write password to security partition" "err"
        return 1
    }

    sleep 1
    read_back="$(dd if="${sec_dev}" bs="${#CRYPTROOT_PASSPHRASE}" count=1 2>/dev/null)"
    if [[ "${read_back}" == "${CRYPTROOT_PASSPHRASE}" ]]; then
        display_alert "secure-storage" "Password written and verified successfully" "info"
    else
        display_alert "secure-storage" "Password write verification failed" "warn"
    fi

    sync
    blockdev --flushbufs "${sec_dev}" 2>/dev/null || true
}
function rk_secure_storage_prepare_partitions() {
    USE_HOOK_FOR_PARTITION="yes"
    [[ "${OTA_ENABLE:-}" == "yes" ]] || {
        BIOSSIZE=0
        UEFISIZE=0
    }
    SECURE_STORAGE_SECURITY_FS_TYPE=${SECURE_STORAGE_SECURITY_FS_TYPE:-none}
    display_alert "secure-storage" "security(${OTA_SECURITY_SIZE:-4}MiB) partitions" "info"
}

function rk_secure_storage_load_ota_partition_size_policy() {
    if [[ "$(type -t ota_get_default_partition_sizes || true)" == "function" ]]; then
        return 0
    fi

    local extension_root helper
    extension_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    helper="${extension_root}/armbian-ota/common/build-hooks/partitions.sh"
    [[ -f "${helper}" ]] || exit_with_error "OTA partition size helper not found" "${helper}"

    # shellcheck source=/dev/null
    source "${helper}"
}

function rk_secure_storage_prepare_image_size() {
    [[ "${OTA_ENABLE:-}" == "yes" ]] && return 0

    local boot_size=0
    rk_secure_storage_load_ota_partition_size_policy
    ota_get_default_partition_sizes

    if [[ -n "${BOOTFS_TYPE:-}" || "${BOOTPART_REQUIRED:-}" == "yes" ]]; then
        BOOTSIZE=${OTA_BOOT_SIZE}
        boot_size=${BOOTSIZE}
    fi

    FIXED_IMAGE_SIZE=$((OFFSET + boot_size + OTA_SECURITY_SIZE + OTA_ROOTFS_SIZE))
    display_alert "secure-storage" "Setting FIXED_IMAGE_SIZE=${FIXED_IMAGE_SIZE} MiB (boot=${boot_size} MiB, security=${OTA_SECURITY_SIZE} MiB, rootfs=${OTA_ROOTFS_SIZE} MiB)" "info"
}

function rk_secure_storage_create_partition_table() {
    if [[ "${OTA_ENABLE:-}" == "yes" ]]; then
        if [[ -n "${SECURE_STORAGE_SECURITY_PART_INDEX:-}" ]]; then
            display_alert "secure-storage" "OTA layout detected, reusing security partition index ${SECURE_STORAGE_SECURITY_PART_INDEX}" "info"
        else
            exit_with_error "OTA security partition index is unset" "OTA partition table must be created before secure-storage"
        fi
        return 0
    fi

    local next="${OFFSET}"
    local p_index=1
    local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
    if [[ "${IMAGE_PARTITION_TABLE:-gpt}" == "gpt" ]]; then
        local gpt_table_length="${SECURE_STORAGE_GPT_TABLE_LENGTH:-64}"
        script+="table-length: ${gpt_table_length}\n"
    fi

    if [[ -n "${BOOTSIZE}" && ${BOOTSIZE} -gt 0 && ( -n "${BOOTFS_TYPE}" || "${BOOTPART_REQUIRED}" == "yes" ) ]]; then
        local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
        if [[ "${BOOT_RAW_MODE}" == "yes" ]]; then
            boot_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
        fi
        script+="${p_index} : name=\"boot\", start=${next}MiB, size=${BOOTSIZE}MiB, type=${boot_type}\n"
        next=$((next + BOOTSIZE)); p_index=$((p_index + 1))
    fi

    local sec_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    local security_part_index=${p_index}
    script+="${p_index} : name=\"security\", start=${next}MiB, size=${OTA_SECURITY_SIZE}MiB, type=${sec_type}\n"
    next=$((next + OTA_SECURITY_SIZE)); p_index=$((p_index + 1))

    local root_type
    if [[ "${IMAGE_PARTITION_TABLE}" == "gpt" ]]; then
        root_type="${PARTITION_TYPE_UUID_ROOT:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
    else
        root_type="83"
    fi
    script+="${p_index} : name=\"rootfs\", start=${next}MiB, size=${OTA_ROOTFS_SIZE}MiB, type=${root_type}\n"
    rootpart=${p_index}

    display_alert "secure-storage" "Custom partition table:\n${script}" "debug"
    printf "%b" "${script}" | run_host_command_logged sfdisk "${SDCARD}.raw" ||
        exit_with_error "secure-storage partition creation failed" "sfdisk"

    SECURE_STORAGE_SECURITY_PART_INDEX=${security_part_index}
}

function rk_secure_storage_verify_layout() {
    if [[ -z "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]]; then
        exit_with_error "secure-storage verification failed" "SECURE_STORAGE_SECURITY_PART_INDEX is empty"
    fi

    local ptable_dump
    ptable_dump="$(sfdisk -d "${SDCARD}.raw" 2>/dev/null || true)"
    if [[ -z "${ptable_dump}" ]]; then
        exit_with_error "secure-storage verification failed: cannot dump partition table" "${SDCARD}.raw"
    fi

    if ! grep -q 'name="security"' <<< "${ptable_dump}"; then
        display_alert "secure-storage" "Partition table dump:" "err"
        echo "${ptable_dump}" || true
        exit_with_error "secure-storage verification failed: no security partition name found" "${SDCARD}.raw"
    fi

    if ! grep -Eq "\\.raw${SECURE_STORAGE_SECURITY_PART_INDEX}([[:space:]]|:).*(name=\"security\")" <<< "${ptable_dump}"; then
        display_alert "secure-storage" "Partition table dump:" "err"
        echo "${ptable_dump}" || true
        exit_with_error "secure-storage verification failed: security index mismatch" "expected index=${SECURE_STORAGE_SECURITY_PART_INDEX}"
    fi

    display_alert "secure-storage" "Security partition table entry verified at index ${SECURE_STORAGE_SECURITY_PART_INDEX}" "info"
}

function rk_secure_storage_format_partitions() {
    [[ -n "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]] || return 0

    local sec_dev="${LOOP}p${SECURE_STORAGE_SECURITY_PART_INDEX}"
    check_loop_device "${sec_dev}"
    [[ -b "${sec_dev}" ]] ||
        exit_with_error "secure-storage verification failed: security partition device missing after loop setup" "${sec_dev}"

    rk_secure_storage_format_partition "${sec_dev}" || return 1
    rk_secure_storage_write_passphrase "${sec_dev}" || return 1
}
