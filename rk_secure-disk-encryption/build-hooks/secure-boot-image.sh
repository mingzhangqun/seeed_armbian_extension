# Secure boot image build hook helpers
function rk_secure_boot_kernel_bootargs() {
    local console_args root_args extra_args

    case "$(rk_detect_platform 2>/dev/null || echo unknown)" in
        rk3588)
            console_args="earlycon=uart8250,mmio32,0xfeb50000 console=ttyFIQ0 irqchip.gicv3_pseudo_nmi=0"
            ;;
        rk3576|*)
            console_args="earlycon=uart8250,mmio32,0x2ad40000 console=ttyFIQ0"
            ;;
    esac

    root_args="${RK_SECURE_BOOT_ROOTARGS:-root=/dev/mapper/armbian-root rw rootwait}"
    extra_args="${RK_SECURE_BOOT_EXTRA_BOOTARGS:-}"

    printf '%s %s' "${console_args}" "${root_args}"
    if [[ -n "${extra_args}" ]]; then
        printf ' %s' "${extra_args}"
    fi
}

function rk_secure_boot_patch_dtb_bootargs() {
    local dtb_file="$1"
    local bootargs="$2"

    [[ -f "${dtb_file}" ]] || exit_with_error "FIT packaging failed: DTB copy missing" "${dtb_file}"
    if ! command -v fdtput >/dev/null 2>&1; then
        exit_with_error "FIT packaging failed: fdtput missing, cannot inject root bootargs" "device-tree-compiler"
    fi

    fdtput -c "${dtb_file}" /chosen 2>/dev/null || true
    fdtput -t s "${dtb_file}" /chosen bootargs "${bootargs}" ||
        exit_with_error "FIT packaging failed: cannot inject /chosen/bootargs" "${dtb_file}"
    display_alert "fit-post-initrd" "Injected DTB bootargs: ${bootargs}" "info"
}

# Bake DEFAULT_OVERLAYS into a DTB copy before FIT/resource.img packaging.
#
# RAW FIT boot has no /boot filesystem, so U-Boot cannot load .dtbo files at
# boot time. Merging overlays into the base DTB on the build host — before
# the FIT is signed — keeps the signature covering the final DTB and makes
# the overlay's effect deterministic across boot modes.
#
# Operates on a copy (board.dtb or the resource.img staging file), not the
# kernel build artifact, so callers must pass the path they intend to embed.
# overlay_dir is the kernel's arch/arm64/boot/dts/rockchip/overlay directory.
function rk_secure_boot_apply_default_overlays() {
    local dtb_file="$1"
    local overlay_dir="$2"

    [[ -n "${DEFAULT_OVERLAYS:-}" ]] || return 0

    [[ -f "${dtb_file}" ]] ||
        exit_with_error "FIT packaging failed: DTB copy missing for overlay merge" "${dtb_file}"
    [[ -d "${overlay_dir}" ]] ||
        exit_with_error "FIT packaging failed: overlay directory missing" "${overlay_dir}"
    command -v fdtoverlay >/dev/null 2>&1 ||
        exit_with_error "FIT packaging failed: fdtoverlay missing" "device-tree-compiler"

    local -a overlay_args=()
    local ov src
    for ov in ${DEFAULT_OVERLAYS}; do
        src="${overlay_dir}/${ov}.dtbo"
        [[ -f "${src}" ]] ||
            exit_with_error "FIT packaging failed: overlay missing" "${src}"
        overlay_args+=("${src}")
    done

    display_alert "fit-post-initrd" "Baking overlays into DTB: ${DEFAULT_OVERLAYS}" "info"

    local tmp_out err_log
    tmp_out="$(mktemp)"
    err_log="$(mktemp)"
    if ! fdtoverlay -i "${dtb_file}" -o "${tmp_out}" "${overlay_args[@]}" 2>"${err_log}"; then
        local err_msg; err_msg="$(< "${err_log}")"
        rm -f "${tmp_out}" "${err_log}"
        exit_with_error "FIT packaging failed: fdtoverlay rejected overlay" "${DEFAULT_OVERLAYS}: ${err_msg}"
    fi
    rm -f "${err_log}"
    mv -f "${tmp_out}" "${dtb_file}"
}

# FIT's ramdisk node takes the RAW gzip cpio; uInitrd-* on /boot is the same
# payload with a 64-byte mkimage legacy header that FIT consumers must NOT see
# (U-Boot boots FIT images directly, no outer uImage unwrap). initrd.img-*
# used to be the raw source, but the slim build-hook prunes it, so resolve in
# order: raw initrd.img-* (legacy layouts) -> strip uInitrd-* mkimage header ->
# bare uInitrd symlink target -> rootfs.cpio.gz fallback.
function rk_secure_boot_strip_uimage_header() {
    local src="$1" dst="$2"

    # mkimage legacy header magic: 0x27051956 at offset 0
    if [[ "$(od -An -tx1 -N4 "${src}" 2>/dev/null | tr -d ' \n')" == "27051956" ]]; then
        dd if="${src}" of="${dst}" bs=64 skip=1 status=none ||
            exit_with_error "FIT packaging failed: cannot strip uImage header" "${src}"
        printf '%s\n' "${dst}"
        return 0
    fi
    printf '%s\n' "${src}"
}

function rk_secure_boot_find_ramdisk() {
    local boot_dir="$1"

    RK_SECURE_BOOT_RAMDISK_PATH=""
    if compgen -G "${boot_dir}/initrd.img-"* > /dev/null; then
        RK_SECURE_BOOT_RAMDISK_PATH="$(ls -1t ${boot_dir}/initrd.img-* | head -1)"
        display_alert "fit-post-initrd" "Using official initrd: ${RK_SECURE_BOOT_RAMDISK_PATH}" "info"
    elif compgen -G "${boot_dir}/uInitrd-"* > /dev/null; then
        local uinitrd_versioned stripped
        uinitrd_versioned="$(ls -1t ${boot_dir}/uInitrd-* | head -1)"
        stripped="$(mktemp -t fit-initrd.XXXXXX)"
        RK_SECURE_BOOT_RAMDISK_PATH="$(rk_secure_boot_strip_uimage_header "${uinitrd_versioned}" "${stripped}")"
        display_alert "fit-post-initrd" "Using uInitrd (mkimage header stripped): ${uinitrd_versioned}" "info"
    elif [[ -f "${boot_dir}/uInitrd" ]]; then
        local stripped
        stripped="$(mktemp -t fit-initrd.XXXXXX)"
        RK_SECURE_BOOT_RAMDISK_PATH="$(rk_secure_boot_strip_uimage_header "${boot_dir}/uInitrd" "${stripped}")"
        display_alert "fit-post-initrd" "Using uInitrd (mkimage header stripped): ${boot_dir}/uInitrd" "info"
    elif [[ -f "${SRC}/userpatches/overlay/rootfs.cpio.gz" ]]; then
        RK_SECURE_BOOT_RAMDISK_PATH="${SRC}/userpatches/overlay/rootfs.cpio.gz"
        display_alert "fit-post-initrd" "Official initrd not found, falling back to rootfs.cpio.gz" "warn"
    else
        exit_with_error "FIT packaging failed: no initramfs found" "${boot_dir}"
    fi
}

function rk_secure_boot_find_kernel_image() {
    local boot_dir="$1"
    local ramdisk_path="$2"
    local kernel_version=""
    local kernel_path=""

    # ramdisk_path may be an initrd.img-*, a stripped mktemp file derived from
    # uInitrd-*, or a bare uInitrd. Recover the kernel version from whichever
    # versioned artifact is on disk; prefer initrd.img-* (raw, paired with
    # vmlinuz), fall back to uInitrd-* (same kernel, mkimage-wrapped).
    case "$(basename "${ramdisk_path}")" in
        initrd.img-*) kernel_version="$(basename "${ramdisk_path}" | sed 's/^initrd\.img-//')" ;;
        uInitrd-*)    kernel_version="$(basename "${ramdisk_path}" | sed 's/^uInitrd-//')" ;;
    esac
    if [[ -z "${kernel_version}" ]]; then
        local cand
        for cand in "${boot_dir}"/initrd.img-* "${boot_dir}"/uInitrd-*; do
            [[ -e "${cand}" ]] || continue
            kernel_version="$(basename "${cand}" | sed -e 's/^initrd\.img-//' -e 's/^uInitrd-//')"
            break
        done
    fi

    if [[ -n "${kernel_version}" && -f "${boot_dir}/vmlinuz-${kernel_version}" ]]; then
        kernel_path="${boot_dir}/vmlinuz-${kernel_version}"
    elif compgen -G "${boot_dir}/vmlinuz-"* > /dev/null; then
        kernel_path="$(ls -1t ${boot_dir}/vmlinuz-* | head -1)"
    fi

    [[ -n "${kernel_path}" && -f "${kernel_path}" ]] ||
        exit_with_error "FIT packaging failed: installed kernel image missing" "${boot_dir}/vmlinuz-*"

    RK_SECURE_BOOT_KERNEL_IMAGE_PATH="${kernel_path}"
    display_alert "fit-post-initrd" "Using installed kernel image: ${RK_SECURE_BOOT_KERNEL_IMAGE_PATH}" "info"
}

function rk_secure_boot_mkimage_supports_signing() {
    local help
    help="$("$1" -h 2>&1 || true)"
    [[ "${help}" != *"Signing / verified boot not supported"* ]]
}

function rk_secure_boot_resolve_mkimage() {
    local rkbin_dir candidate

    RK_SECURE_BOOT_MKIMAGE=""

    # The per-platform rkbin dirs ship different mkimage builds: rk3576_rkbin's
    # is statically linked with FIT signature support, while rk3588_rkbin's is
    # built without CONFIG_FIT_SIGNATURE and silently emits unsigned FITs.
    # mkimage is a host tool and FIT signing is SoC-agnostic, so any
    # signing-capable prebuilt serves both platforms.
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    local candidates=(
        "${rkbin_dir}/tools/mkimage"
        "$(rk_sdk_rkbin_root)/rk3576_rkbin/tools/mkimage"
        "$(rk_sdk_rkbin_root)/rk3588_rkbin/tools/mkimage"
        "$(rk_sdk_rkbin_root)/tools/mkimage"
    )
    for candidate in "${candidates[@]}"; do
        [[ -x "${candidate}" ]] || continue
        rk_secure_boot_mkimage_supports_signing "${candidate}" || continue
        RK_SECURE_BOOT_MKIMAGE="${candidate}"
        break
    done

    [[ -x "${RK_SECURE_BOOT_MKIMAGE}" ]] ||
        exit_with_error "FIT signing failed: no signing-capable mkimage under" "$(rk_sdk_rkbin_root)"
}

function rk_secure_boot_prepare_fit_workdir() {
    local fit_work="$1"
    local kernel_img_path="$2"
    local dtb_path="$3"
    local resource_path="$4"
    local ramdisk_path="$5"

    rm -rf "${fit_work}" 2>/dev/null || true
    mkdir -p "${fit_work}" || exit_with_error "FIT packaging failed: cannot create temporary directory" "${fit_work}"

    cp -f "${kernel_img_path}" "${fit_work}/Image"
    cp -f "${dtb_path}" "${fit_work}/board.dtb"
    if [[ -f "${resource_path}" ]]; then
        cp -f "${resource_path}" "${fit_work}/resource.img"
    else
        : > "${fit_work}/resource.img"
    fi
    cp -f "${ramdisk_path}" "${fit_work}/initrd.img"
    rk_secure_boot_apply_default_overlays "${fit_work}/board.dtb" "$(dirname "${dtb_path}")/overlay"
    rk_secure_boot_patch_dtb_bootargs "${fit_work}/board.dtb" "$(rk_secure_boot_kernel_bootargs)"
}

function rk_secure_boot_apply_fit_template() {
    local fit_work="$1"
    local its_template

    its_template="$(resolve_platform_its_template)"
    if [[ ! -f "${its_template}" ]]; then
        exit_with_error "FIT packaging failed: ITS template missing" "$(rk_resolve_extension_dir "u-boot/fit-kernel")/u-boot/fit-kernel"
    fi
    display_alert "fit-post-initrd" "Using ITS template: ${its_template}" "info"

    cp -f "${its_template}" "${fit_work}/boot-final.its"
    sed -i "s|@KERNEL_DTB@|${fit_work}/board.dtb|g" "${fit_work}/boot-final.its"
    sed -i "s|@KERNEL_IMG@|${fit_work}/Image|g" "${fit_work}/boot-final.its"
    sed -i "s|@RAMDISK_IMG@|${fit_work}/initrd.img|g" "${fit_work}/boot-final.its"
    sed -i "s|@RESOURCE_IMG@|${fit_work}/resource.img|g" "${fit_work}/boot-final.its"
}

function rk_secure_boot_generate_initial_fit() {
    local fit_work="$1"
    local rk_mkimage="$2"

    display_alert "fit-post-initrd" "Generating final FIT (initial boot-final.img)" "info"
    (
        cd "${fit_work}" || exit 1
        "${rk_mkimage}" -f boot-final.its  -E -p 0x800 boot-final.img || exit 1
    ) || { rm -rf "${fit_work}"; exit_with_error "FIT packaging failed: mkimage generation failed" "${fit_work}/boot-final.its"; }
}

function rk_secure_boot_resolve_uboot_dir() {
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"

    RK_SECURE_BOOT_UBOOT_DIR="${uboot_src}"
    if [[ -z "${RK_SECURE_BOOT_UBOOT_DIR}" || ! -d "${RK_SECURE_BOOT_UBOOT_DIR}" ]]; then
        RK_SECURE_BOOT_UBOOT_DIR="$(find "${SRC}/cache/sources/u-boot-worktree" -maxdepth 4 -type d -name "u-boot-*${LINUXFAMILY}*" | head -1)"
    fi
}

function rk_secure_boot_run_secondary_fit_signing() {
    local fit_work="$1"
    local uboot_dir="$2"
    local fit_padding="0x1000"

    rm -f "${uboot_dir}/fit/boot.itb" "${uboot_dir}/boot-final.img" 2>/dev/null || true

    if [[ ! -x "${uboot_dir}/tools/fit_check_sign" ]]; then
        if rk_full_secure_boot_enabled; then
            exit_with_error "FIT signing failed: fit_check_sign missing" "${uboot_dir}/tools/fit_check_sign"
        fi
        display_alert "fit-post-initrd" "fit_check_sign not found, using unsigned fallback image" "warn"
        return 0
    fi

    if grep -q '^CONFIG_FIT_ENABLE_RSA4096_SUPPORT=y' "${uboot_dir}/.config" 2>/dev/null; then
        fit_padding="0x1200"
    fi

    # The boot FIT carries padding = "pss", and the on-board verifiers (SPL /
    # U-Boot from the radxa v2024.10 tree) only accept maximum-salt PSS
    # signatures.  A tree-built mkimage linked against OpenSSL >= 3.5 signs
    # with digest-length salt, which the device rejects.  Sign with the
    # Rockchip prebuilt mkimage instead: it is statically linked, so its
    # maximum-salt behaviour is frozen into the binary regardless of the
    # build container's OpenSSL.
    [[ -x "${RK_SECURE_BOOT_MKIMAGE}" ]] || rk_secure_boot_resolve_mkimage

    # USBPLUG postprocessing can leave a stale tools/mkimage built from a
    # temporary config without CONFIG_FIT_SIGNATURE.  That also leaves
    # fit_check_sign failing with "No RSA key found".  Rebuild the host tools
    # from the final secure U-Boot configuration before verifying the FIT.
    if [[ -x "${uboot_dir}/tools/mkimage" ]] &&
        "${uboot_dir}/tools/mkimage" -h 2>&1 | grep -q 'Signing / verified boot not supported'; then
        make -C "${uboot_dir}" -B tools-only || exit_with_error "FIT signing failed: unable to rebuild U-Boot host tools" "${uboot_dir}/tools"
    fi

    display_alert "fit-post-initrd" "Signing final FIT from boot-final.its" "info"
    (
        cd "${uboot_dir}" || exit 1
        mkdir -p fit
        # The U-Boot build phase already embeds key-dev into u-boot.dtb.
        # Re-injecting it here is redundant and can exhaust DTB free space.
        "${RK_SECURE_BOOT_MKIMAGE}" -f "${fit_work}/boot-final.its" -k keys/ -E -p "${fit_padding}" -r fit/boot.itb || exit 1
        fdtget -l u-boot.dtb /signature 2>/dev/null | grep -qx 'key-dev' || exit 1
        # Tree-built verifier: same verify code as the running U-Boot, so a
        # salt drift in the signing tool fails the build instead of the boot.
        ./tools/fit_check_sign -f fit/boot.itb -k u-boot.dtb || exit 1
    ) || {
        if rk_full_secure_boot_enabled; then
            exit_with_error "FIT signing failed: mkimage signing failed" "${fit_work}/boot-final.its"
        fi
        display_alert "fit-post-initrd" "FIT signing failed, using unsigned fallback image" "warn"
    }
}

function rk_secure_boot_stage_final_fit() {
    local fit_work="$1"
    local uboot_dir="$2"
    local fit_output_candidate=""
    local canonical_fit_image="${SRC}/cache/sources/${BOOTSOURCEDIR}/fit/boot.itb"

    if [[ -f "${uboot_dir}/fit/boot.itb" ]]; then
        fit_output_candidate="${uboot_dir}/fit/boot.itb"
    elif [[ -f "${uboot_dir}/boot-final.img" ]]; then
        fit_output_candidate="${uboot_dir}/boot-final.img"
    elif [[ -f "${fit_work}/boot-final.img" ]]; then
        fit_output_candidate="${fit_work}/boot-final.img"
    else
        rm -rf "${fit_work}" 2>/dev/null || true
        exit_with_error "FIT packaging failed: no final FIT image generated" "${uboot_dir}/fit/boot.itb"
    fi

    mkdir -p "$(dirname "${canonical_fit_image}")" ||
        exit_with_error "FIT packaging failed: cannot create fit output directory" "$(dirname "${canonical_fit_image}")"
    if [[ "${fit_output_candidate}" == "${canonical_fit_image}" ]] || \
       [[ -e "${canonical_fit_image}" && "${fit_output_candidate}" -ef "${canonical_fit_image}" ]]; then
        display_alert "fit-post-initrd" "Final FIT image already in canonical location: ${canonical_fit_image}" "info"
    else
        cp -f "${fit_output_candidate}" "${canonical_fit_image}" ||
            exit_with_error "FIT packaging failed: cannot stage final fit image" "${canonical_fit_image}"
    fi

    export RK_SECURE_BOOT_FIT_IMAGE="${canonical_fit_image}"
    display_alert "fit-post-initrd" "Final FIT image ready: ${RK_SECURE_BOOT_FIT_IMAGE}" "info"
}

function rk_secure_boot_remove_boot_fstab_entries() {
    local fstab_file="${MOUNT}/etc/fstab"

    display_alert "fit-flash" "Removing boot settings from fstab" "info"

    if [[ ! -f "${fstab_file}" ]]; then
        display_alert "fit-flash" "No fstab file" "info"
        return 0
    fi

    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        display_alert "fit-flash" "No boot entries" "info"
        return 0
    fi

    display_alert "secure-uboot" "Removing boot partition mount entries from fstab" "info"
    display_alert "secure-uboot" "fstab content before sed execution:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    cp "${fstab_file}" "${fstab_file}.bak" 2>/dev/null || true
    sed -i '\|/boot|d' "${fstab_file}" 2>/dev/null || true

    display_alert "secure-uboot" "fstab content after sed execution:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        rm -f "${fstab_file}.bak" 2>/dev/null || true
        display_alert "secure-uboot" "Successfully removed boot partition mount entries from fstab" "info"
    else
        display_alert "secure-uboot" "Warning: /boot entries still exist in fstab, please check manually" "warn"
    fi
}

function rk_secure_boot_disable_kernel_root_symlinks() {
    local root_dir="$1"
    local conf_file="${root_dir}/etc/kernel-img.conf"

    display_alert "secure-uboot" "Disabling Debian kernel root symlinks for RAW FIT boot" "info"

    [[ -n "${root_dir}" ]] || {
        display_alert "secure-uboot" "Cannot disable kernel symlinks: root dir is empty" "warn"
        return 0
    }

    mkdir -p "${root_dir}/etc" || {
        display_alert "secure-uboot" "Cannot create ${root_dir}/etc" "warn"
        return 0
    }

    touch "${conf_file}" || {
        display_alert "secure-uboot" "Cannot create ${conf_file}" "warn"
        return 0
    }
    sed -i -E '/^[[:space:]]*do_symlinks[[:space:]]*=/d' "${conf_file}" || true
    cat >> "${conf_file}" <<'EOF'

# RAW FIT images boot from a non-filesystem boot partition.
do_symlinks = No
EOF
}
function modify_boot_partition_name() {
    export BOOT_FS_LABEL="boot"
    display_alert "secure-uboot" "Set boot partition label to: ${BOOT_FS_LABEL}" "info"
}

function rk_secure_boot_apply_boot_partition_label() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    modify_boot_partition_name
    mkopts_label[ext4]=" -U 0b06166d-3930-4176-b30a-900806bd6202 -L  "
}

function rk_secure_boot_capture_raw_boot_partition() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    display_alert "secure-uboot" "RAW boot mode: Save bootpart index and prevent filesystem creation" "debug"

    # Ensure BOOTSIZE is set
    if [[ -z "${BOOTSIZE}" ]]; then
        export BOOTSIZE=256
        display_alert "secure-uboot" "Setting default BOOTSIZE=${BOOTSIZE} MiB" "info"
    fi

    # Save original bootpart index for later dd write
    export RAW_BOOT_PART_INDEX="${bootpart}"
    display_alert "secure-uboot" "Saved boot partition index: ${RAW_BOOT_PART_INDEX}" "debug"

    # Delay clearing bootpart variable, clear it in mount_chroot_script stage
    # This ensures correct use of BOOTSIZE during partition creation
}
function rk_secure_boot_create_resource_img() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local dtb_path
    dtb_path="$(resolve_kernel_dtb_path "${kernel_src}")"
    display_alert "Creating resource.img" "Using DTB: ${dtb_path:-<not found>}" "info"
    local resource_tool="${uboot_src}/tools/resource_tool"
    local output_resource_img="${kernel_src}/resource.img"

    # Check necessary files and tools
    [[ -f "${dtb_path}" ]] ||
        exit_with_error "Missing DTB file for resource.img" "${dtb_path}"

    [[ -n "${resource_tool}" && -x "${resource_tool}" ]] ||
        exit_with_error "Missing resource_tool" "${resource_tool}"

    display_alert "Using resource_tool" "${resource_tool}" "debug"

    # Create temporary work directory
    local temp_work_dir
    temp_work_dir="$(mktemp -d)" ||
        exit_with_error "Failed to create temporary resource.img work directory" "${TMPDIR:-/tmp}"

    # Copy DTB file to work directory and inject bootargs before packing resource.img.
    # Rockchip vendor boot flows may pass the DTB from resource.img rather than the
    # FIT fdt image, so both copies must carry a valid root= argument.
    local dtb_filename
    dtb_filename="$(basename "${dtb_path}")"
    cp "${dtb_path}" "${temp_work_dir}/${dtb_filename}" ||
        exit_with_error "Failed to copy DTB for resource.img" "${dtb_path}"
    rk_secure_boot_patch_dtb_bootargs "${temp_work_dir}/${dtb_filename}" "$(rk_secure_boot_kernel_bootargs)"

    # Ensure output directory exists and is writable
    local output_dir
    output_dir="$(dirname "${output_resource_img}")"
    mkdir -p "${output_dir}" ||
        exit_with_error "Failed to create resource.img output directory" "${output_dir}"

    # Use resource_tool to create resource.img
    (
        cd "${temp_work_dir}"

        display_alert "resource.img" "Packing DTB ${dtb_filename} -> ${output_resource_img}" "debug"

        # Create in current directory first, then move to target location
        "${resource_tool}" --pack "${dtb_filename}" "./resource.img" || {
            display_alert "Failed to create resource.img in temp dir" "resource_tool pack failed" "err"
            rm -rf "${temp_work_dir}"
            return 1
        }

        # Move to final location
        if [[ -f "./resource.img" ]]; then
            mv "./resource.img" "${output_resource_img}" || {
                display_alert "Failed to move resource.img to ${output_resource_img}" "mv failed" "err"
                rm -rf "${temp_work_dir}"
                return 1
            }
        else
            display_alert "resource.img not created in temp directory" "file missing" "err"
            rm -rf "${temp_work_dir}"
            return 1
        fi
    )

    # Clean up temporary directory
    rm -rf "${temp_work_dir}"

    # Verify generated resource.img
    if [[ -f "${output_resource_img}" && -s "${output_resource_img}" ]]; then
        local img_size
        img_size="$(stat -c %s "${output_resource_img}")"
        display_alert "Successfully created resource.img" "Size: ${img_size} bytes" "info"

        # Optional: Display resource.img content
        "${resource_tool}" --print --image="${output_resource_img}" 2>/dev/null || true
    else
        display_alert "Failed to create resource.img" "File not found or empty" "err"
        return 1
    fi
}

function rk_secure_boot_package_final_fit() {
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    local boot_dir="${MOUNT}/boot"  # Use real /boot from mount point
    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local kernel_img_path
    local resource_path="${kernel_src}/resource.img"
    local fit_work="${TMPDIR:-/tmp}/fit-final-$$"
    local dtb_path

    display_alert "fit-post-initrd" "Starting to rebuild FIT before final unmount" "info"
    [[ -d "${boot_dir}" ]] || exit_with_error "FIT packaging failed: /boot does not exist" "${boot_dir}"

    rk_secure_boot_find_ramdisk "${boot_dir}"
    rk_secure_boot_find_kernel_image "${boot_dir}" "${RK_SECURE_BOOT_RAMDISK_PATH}"
    kernel_img_path="${RK_SECURE_BOOT_KERNEL_IMAGE_PATH}"

    dtb_path="$(resolve_kernel_dtb_path "${kernel_src}")"
    display_alert "fit-post-initrd" "Embedding DTB into FIT: ${dtb_path} (name=$(basename "${dtb_path}" 2>/dev/null || echo unknown))" "info"
    [[ -f "${kernel_img_path}" ]] || exit_with_error "FIT packaging failed: kernel image missing" "${kernel_img_path}"
    [[ -f "${dtb_path}" ]] || exit_with_error "FIT packaging failed: DTB missing" "${dtb_path}"

    rk_secure_boot_resolve_mkimage
    rk_secure_boot_prepare_fit_workdir "${fit_work}" "${kernel_img_path}" "${dtb_path}" "${resource_path}" "${RK_SECURE_BOOT_RAMDISK_PATH}"
    rk_secure_boot_apply_fit_template "${fit_work}"
    rk_secure_boot_generate_initial_fit "${fit_work}" "${RK_SECURE_BOOT_MKIMAGE}"
    rk_secure_boot_resolve_uboot_dir
    rk_secure_boot_run_secondary_fit_signing "${fit_work}" "${RK_SECURE_BOOT_UBOOT_DIR}"
    rk_secure_boot_stage_final_fit "${fit_work}" "${RK_SECURE_BOOT_UBOOT_DIR}"

    rm -rf "${fit_work}" 2>/dev/null || true
    rk_secure_boot_remove_boot_fstab_entries
}

function rk_secure_boot_flash_fit_kernel() {
    # After final unmount, write FIT image to boot partition (only in RAW boot mode)
    if ! rk_autodecrypt_fit_boot_required; then
        return 0
    fi

    display_alert "fit-flash" "RAW boot mode: Writing FIT image to boot partition" "info"

    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local fit_image="${RK_SECURE_BOOT_FIT_IMAGE:-${uboot_src}/fit/boot.itb}"
    local boot_part_index="${RAW_BOOT_PART_INDEX:-1}"
    local boot_dev="${LOOP}p${boot_part_index}"

    display_alert "fit-flash" "Target boot device: ${boot_dev}" "info"

    if [[ ! -f "${fit_image}" ]]; then
        exit_with_error "FIT flash failed: FIT image does not exist" "${fit_image}"
    fi

    [[ -b "${boot_dev}" ]] || exit_with_error "FIT flash failed: target boot partition does not exist" "${boot_dev}"

    display_alert "fit-flash" "dd if=${fit_image} of=${boot_dev}" "info"
    dd if="${fit_image}" of="${boot_dev}" conv=fsync || exit_with_error "FIT flash failed: dd write error" "${boot_dev}"

    sync
    display_alert "fit-flash" "FIT image write completed" "info"
}
