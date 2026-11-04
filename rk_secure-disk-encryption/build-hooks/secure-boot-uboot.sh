# Secure boot U-Boot build hook helpers
function resolve_platform_rkbin_dir() {
    # Resolve platform-specific rkbin content directory.
    # Expected layout examples:
    # 1) rkbin/rk3576_rkbin/{RKTRUST,tools,...}
    # 2) rkbin/rk3588_rkbin/{RKTRUST,tools,...}
    # 3) legacy rkbin/{RKTRUST,tools,...}
    local rkbin_root platform rkbin_dir candidate
    rkbin_root="$(rk_sdk_rkbin_root)"
    platform="$(rk_detect_platform)"

    [[ "${platform}" != "unknown" ]] && rkbin_dir="${rkbin_root}/${platform}_rkbin"

    if [[ -n "${rkbin_dir}" && -d "${rkbin_dir}" ]]; then
        echo "${rkbin_dir}"
        return 0
    fi

    # If platform cannot be detected and both platform rkbin directories exist,
    # returning one arbitrarily is unsafe.
    if [[ "${platform}" == "unknown" && -d "${rkbin_root}/rk3576_rkbin" && -d "${rkbin_root}/rk3588_rkbin" ]]; then
        echo ""
        return 1
    fi

    if [[ -d "${rkbin_root}/RKTRUST" || -d "${rkbin_root}/tools" ]]; then
        echo "${rkbin_root}"
        return 0
    fi

    candidate="$(find "${rkbin_root}" -maxdepth 1 -mindepth 1 -type d -name "*_rkbin" | sort | head -n1)"
    if [[ -n "${candidate}" ]]; then
        echo "${candidate}"
        return 0
    fi

    echo "${rkbin_root}"
}

function resolve_platform_its_template() {
    # Match FIT load addresses to U-Boot's per-SoC ENV_MEM_LAYOUT_SETTINGS.
    rk_secure_kernel_fit_template_path || true
}

function resolve_platform_bl32_blob() {
    local platform="$1"

    case "${platform}" in
        rk3576) echo "rk35/rk3576_bl32_v1.08.bin" ;;
        rk3588) echo "rk35/rk3588_bl32_v1.20.bin" ;;
        *) echo "" ;;
    esac
}

function rk_secure_boot_prepare_tee_bin() {
    local uboot_workdir="$1"
    local platform bl32_blob bl32_path

    platform="$(rk_detect_platform)"
    bl32_blob="$(resolve_platform_bl32_blob "${platform}")"
    if [[ -z "${bl32_blob}" ]]; then
        exit_with_error "No BL32 blob mapping found" "BOOT_SOC=${BOOT_SOC:-} BOARD=${BOARD:-}"
    fi

    bl32_path="${SRC}/cache/sources/rkbin-tools/${bl32_blob}"
    if [[ ! -f "${bl32_path}" ]]; then
        exit_with_error "BL32 blob missing" "${bl32_path}"
    fi

    install -m 0644 "${bl32_path}" "${uboot_workdir}/tee.bin" ||
        exit_with_error "Failed to stage BL32 as tee.bin" "${uboot_workdir}/tee.bin"
    display_alert "secure-uboot" "Staged BL32 for U-Boot FIT: ${bl32_blob} -> tee.bin" "info"
}

function resolve_kernel_dtb_path() {
    # Resolve kernel DTB path for resource/FIT packaging.
    # Priority:
    # 1) RK_SECURE_KERNEL_DTB absolute path
    # 2) RK_SECURE_KERNEL_DTB filename under kernel rockchip dtb dir
    # 3) board + platform based candidate list (BOARD_NAME + BOOT_SOC)
    local kernel_src="$1"
    local dtb_dir platform board candidate override

    dtb_dir="${kernel_src}/arch/arm64/boot/dts/rockchip"
    override="${RK_SECURE_KERNEL_DTB:-}"

    if [[ -n "${override}" ]]; then
        if [[ -f "${override}" ]]; then
            echo "${override}"
            return 0
        fi
        if [[ -f "${dtb_dir}/${override}" ]]; then
            echo "${dtb_dir}/${override}"
            return 0
        fi
        display_alert "secure-uboot" "RK_SECURE_KERNEL_DTB not found: ${override}" "warn"
    fi

    platform="$(rk_detect_platform)"
    board="$(rk_detect_vendor_board)"

    if [[ "${platform}" != "unknown" && "${board}" != "unknown" ]]; then
        for candidate in \
            "${platform}-${board}.dtb" \
            "${platform}-recomputer-devkit.dtb"; do
            [[ -f "${dtb_dir}/${candidate}" ]] && { echo "${dtb_dir}/${candidate}"; return 0; }
        done
    fi

    echo ""
}
function rk_secure_boot_stage_uboot_fit_generator() {
    local uboot_workdir="$1"
    local generator_src generator_dst

    generator_src="$(rk_secure_uboot_fit_generator_path)" ||
        exit_with_error "Secure U-Boot FIT generator missing" "$(rk_resolve_extension_dir "u-boot/fit-generator")/u-boot/fit-generator/make_fit_atf_optee.sh"
    generator_dst="${uboot_workdir}/arch/arm/mach-rockchip/make_fit_atf_optee.sh"

    install -m 0755 "${generator_src}" "${generator_dst}" ||
        exit_with_error "Failed to stage U-Boot FIT generator" "${generator_dst}"
}

function rk_secure_boot_apply_config_fragment() {
    local fragment="$1"

    rk_apply_kconfig_fragment scripts/config "${fragment}" ||
        exit_with_error "Failed to apply secure U-Boot config fragment" "${fragment}"
    display_alert "secure-uboot" "Applied U-Boot config fragment: ${fragment}" "info"
}
function enable_optee_bootchain_bl32_fit_node() {
    # Non-secure OP-TEE bootchain still needs BL32 packed into vendor u-boot.itb.
    # Keep this as a narrow local change instead of reusing the full secure-boot overlay.
    local fit_generator="arch/arm/mach-rockchip/make_fit_atf.sh"

    if [[ ! -f "${fit_generator}" ]]; then
        display_alert "secure-uboot" "OP-TEE bootchain: FIT generator not found, skipping BL32 enable" "warn"
        return 0
    fi

    if grep -q '^[[:space:]]*gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        display_alert "secure-uboot" "OP-TEE bootchain: BL32 FIT node already enabled" "debug"
        return 0
    fi

    if grep -q '^[[:space:]]*#gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        sed -i 's/^[[:space:]]*#gen_bl32_node[[:space:]]*$/gen_bl32_node/' "${fit_generator}" ||
            exit_with_error "Failed to enable BL32 FIT node for OP-TEE bootchain" "${fit_generator}"
        display_alert "secure-uboot" "OP-TEE bootchain: enabled BL32 FIT node in ${fit_generator}" "info"
        return 0
    fi

    display_alert "secure-uboot" "OP-TEE bootchain: no commented gen_bl32_node marker found, leaving ${fit_generator} unchanged" "warn"
}

function rk_secure_boot_verify_fit_images() {
    local fit_image="$1"
    local fit_info

    [[ -f "${fit_image}" ]] || exit_with_error "FIT image missing after U-Boot build" "${fit_image}"

    if ! command -v dumpimage >/dev/null 2>&1; then
        display_alert "secure-uboot" "dumpimage not found, skip FIT image content verification" "warn"
        return 0
    fi

    fit_info="$(dumpimage -l "${fit_image}" 2>/dev/null || true)"
    [[ -n "${fit_info}" ]] || exit_with_error "Failed to parse FIT image" "${fit_image}"

    # For auto-decryption mode, BL32(OP-TEE) and the third ATF loadable are mandatory.
    if rk_autodecrypt_enabled; then
        grep -Eq 'Image [0-9]+ \(atf-3\)' <<< "${fit_info}" ||
            exit_with_error "FIT image validation failed: missing atf-3 loadable" "${fit_image}"
        grep -Eq 'Image [0-9]+ \(optee\)' <<< "${fit_info}" ||
            exit_with_error "FIT image validation failed: missing optee loadable" "${fit_image}"
    fi

    display_alert "secure-uboot" "FIT image validation passed (${fit_image})" "info"
}

function rk_secure_boot_check_produced_fit_image() {
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    [[ "${base_binfile}" == "u-boot.itb" ]] || return 0
    rk_secure_boot_verify_fit_images "${binfile}"
}

function rk_secure_boot_rebuild_idbloader() {
    # The normal Rockchip post-process runs before this signing hook.  Rebuild
    # its loader afterwards so the boot media contains the SPL DTB into which
    # mkimage injected the FIT public key, rather than the pre-signing SPL.
    local spl_bin_path

    case "${BOOT_SCENARIO:-}" in
        spl-blobs)
            spl_bin_path="${RKBIN_DIR}/${DDR_BLOB}"
            [[ -f "${spl_bin_path}" ]] || exit_with_error "DDR blob missing while rebuilding signed idbloader" "${spl_bin_path}"

            if declare -F board_uboot_spl_blobs_postprocess >/dev/null; then
                board_uboot_spl_blobs_postprocess "${BOOT_SOC}" "${spl_bin_path}" "./spl/u-boot-spl.bin"
            else
                rk_run_host_command tools/mkimage -n "${BOOT_SOC_MKIMAGE}" -T rksd \
                    -d "${spl_bin_path}:spl/u-boot-spl.bin" idbloader.img ||
                    exit_with_error "Failed to rebuild idbloader with signed SPL" "${BOOT_SOC}"
            fi
            ;;
        vendor-spl-blobs)
            # A vendor SPL cannot contain the FIT public key generated for this
            # build.  Continuing here would package an image that looks signed
            # but whose first mutable stage cannot validate U-Boot.
            exit_with_error "Full secure boot is incompatible with vendor-spl-blobs" "Use BOOT_SCENARIO=spl-blobs so the signed SPL is deployed"
            ;;
        *)
            exit_with_error "Unsupported secure U-Boot loader scenario" "BOOT_SCENARIO=${BOOT_SCENARIO:-<unset>}"
            ;;
    esac

    [[ -f idbloader.img ]] || exit_with_error "Signed idbloader was not produced" "${PWD}/idbloader.img"
}

function rk_secure_boot_sign_loader_artifacts() {
    local rk_sign_tool="$1" platform="$2" keys_dir="$3"

    "${rk_sign_tool}" cc --chip "${platform#rk}" ||
        exit_with_error "Failed to select Rockchip secure-boot chip" "${platform}"
    "${rk_sign_tool}" lk --key "${keys_dir}/dev.key" --pubkey "${keys_dir}/dev.pubkey" ||
        exit_with_error "Failed to load Rockchip secure-boot signing key" "${keys_dir}"
    "${rk_sign_tool}" sb --idb idbloader.img ||
        exit_with_error "Failed to sign idbloader" "${PWD}/idbloader.img"
    "${rk_sign_tool}" vb --idb idbloader.img ||
        exit_with_error "Signed idbloader verification failed" "${PWD}/idbloader.img"

    # Maskrom recovery uses this separately packaged loader, so it must carry
    # the same signed SPL when the board hook generated one.
    if [[ -f spl_loader_maskrom.bin ]]; then
        "${rk_sign_tool}" sl --loader spl_loader_maskrom.bin ||
            exit_with_error "Failed to sign Maskrom SPL loader" "${PWD}/spl_loader_maskrom.bin"
        "${rk_sign_tool}" vl --loader spl_loader_maskrom.bin ||
            exit_with_error "Signed Maskrom SPL loader verification failed" "${PWD}/spl_loader_maskrom.bin"
    fi
}

function rk_secure_boot_rebuild_spi_loader() {
    [[ "${BOOT_SUPPORT_SPI:-no}" == "yes" ]] || return 0

    if [[ "${BOOT_SPI_RKSPI_LOADER:-no}" == "yes" ]]; then
        rk_run_host_command dd if=/dev/zero of=rkspi_loader.img bs=1M count=0 seek=16 ||
            exit_with_error "Failed to initialise signed SPI loader image" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img mklabel gpt || exit_with_error "Failed to create signed SPI loader GPT" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart idbloader 64 7167 || exit_with_error "Failed to create SPI idbloader partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart vnvm 7168 7679 || exit_with_error "Failed to create SPI vnvm partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart reserved_space 7680 8063 || exit_with_error "Failed to create SPI reserved-space partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart reserved1 8064 8127 || exit_with_error "Failed to create SPI reserved1 partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart uboot_env 8128 8191 || exit_with_error "Failed to create SPI U-Boot env partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart reserved2 8192 16383 || exit_with_error "Failed to create SPI reserved2 partition" "rkspi_loader.img"
        rk_run_host_command /sbin/parted -s rkspi_loader.img unit s mkpart uboot 16384 32734 || exit_with_error "Failed to create SPI U-Boot partition" "rkspi_loader.img"
        rk_run_host_command dd if=idbloader.img of=rkspi_loader.img seek=64 conv=notrunc || exit_with_error "Failed to place signed idbloader in SPI image" "rkspi_loader.img"
        rk_run_host_command dd if=u-boot.itb of=rkspi_loader.img seek=16384 conv=notrunc || exit_with_error "Failed to place signed U-Boot FIT in SPI image" "rkspi_loader.img"
    else
        [[ -f tpl/u-boot-tpl.bin ]] || exit_with_error "TPL missing while rebuilding signed SPI loader" "tpl/u-boot-tpl.bin"
        rk_run_host_command tools/mkimage -n "${BOOT_SOC_MKIMAGE}" -T rkspi \
            -d tpl/u-boot-tpl.bin:spl/u-boot-spl.bin rkspi_tpl_spl.img ||
            exit_with_error "Failed to build signed SPI TPL/SPL image" "rkspi_tpl_spl.img"
        rk_run_host_command dd if=/dev/zero of=rkspi_loader.img count=8128 status=none || exit_with_error "Failed to initialise signed SPI loader image" "rkspi_loader.img"
        rk_run_host_command dd if=rkspi_tpl_spl.img of=rkspi_loader.img conv=notrunc status=none || exit_with_error "Failed to place signed TPL/SPL in SPI image" "rkspi_loader.img"
        rk_run_host_command dd if=u-boot.itb of=rkspi_loader.img seek=768 conv=notrunc status=none || exit_with_error "Failed to place signed U-Boot FIT in SPI image" "rkspi_loader.img"
    fi
}

function rk_secure_boot_minimize_spl_fit_key() {
    # Do not reduce the key material. RK3588 SPL FIT verification needs the
    # complete RSA public key; clearing rsa,r-squared or rsa,c leaves the DTB
    # node present but makes SPL report "No RSA key found" at boot.
    local spl_dtb="spl/u-boot-spl.dtb"
    local key_node="/signature/key-dev"
    local property value

    fdtget -l "${spl_dtb}" /signature 2>/dev/null | grep -qx 'key-dev' ||
        exit_with_error "SPL FIT public key node missing" "${spl_dtb}"
    for property in rsa,modulus rsa,r-squared rsa,c rsa,np rsa,n0-inverse rsa,exponent; do
        value="$(fdtget -t bx "${spl_dtb}" "${key_node}" "${property}" 2>/dev/null)"
        [[ -n "${value}" && "${value}" != '0' ]] ||
            exit_with_error "SPL FIT public key property missing" "${spl_dtb}:${property}"
    done
}

function rk_secure_boot_repack_signed_spl() {
    local spl_bin="spl/u-boot-spl.bin"
    local spl_nodtb="spl/u-boot-spl-nodtb.bin"
    local spl_pad="spl/u-boot-spl-pad.bin"
    local spl_dtb="spl/u-boot-spl.dtb"

    cat "${spl_nodtb}" > "${spl_bin}" || exit_with_error "Failed to start signed SPL repack" "${spl_bin}"
    if ! grep -qx 'CONFIG_SPL_SEPARATE_BSS=y' .config; then
        [[ -f "${spl_pad}" ]] || exit_with_error "SPL pad missing while repacking signed SPL" "${spl_pad}"
        cat "${spl_pad}" >> "${spl_bin}" || exit_with_error "Failed to append SPL pad" "${spl_bin}"
    fi
    cat "${spl_dtb}" >> "${spl_bin}" || exit_with_error "Failed to append signed SPL DTB" "${spl_bin}"
}

function rk_secure_boot_sign_uboot_fit() {
    # Sign the Armbian-built ITS directly. Do not call Rockchip scripts/fit.sh:
    # with CONFIG_FIT_SIGNATURE it invokes make.sh --raw-compile and silently
    # rebuilds the already-built Armbian U-Boot with the vendor toolchain.
    # This hook instead injects the public key into the existing SPL DTB,
    # repacks the existing SPL, and host-verifies the resulting FIT.
    rk_full_secure_boot_enabled || return 0

    local platform keys_dir rk_sign_tool signed_fit fit_padding
    platform="$(rk_detect_platform)"
    keys_dir="${UBOOT_FIT_KEYS_DIR:-${PWD}/keys}"
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    [[ -n "${rk_sign_tool}" ]] || rk_sign_tool="$(resolve_platform_rkbin_dir)/tools/rk_sign_tool"

    [[ "${platform}" != "unknown" ]] || exit_with_error "Cannot sign U-Boot FIT for unknown Rockchip platform" "BOOT_SOC=${BOOT_SOC:-}"
    [[ -x tools/mkimage && -x tools/fit_check_sign ]] || exit_with_error "Rockchip FIT signing tools missing" "${PWD}"
    command -v fdtget >/dev/null 2>&1 || exit_with_error "fdtget is required for secure U-Boot FIT signing" "host dependency missing"
    [[ -x "${rk_sign_tool}" ]] || exit_with_error "rk_sign_tool missing for secure U-Boot build" "${rk_sign_tool}"
    [[ -f .config && -f u-boot.its && -f spl/u-boot-spl.dtb && -f spl/u-boot-spl-nodtb.bin ]] ||
        exit_with_error "U-Boot signing inputs missing" "${PWD}"
    [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.pubkey" && -f "${keys_dir}/dev.crt" ]] ||
        exit_with_error "FIT signing key material missing" "${keys_dir}"
    grep -qx 'CONFIG_FIT_SIGNATURE=y' .config || exit_with_error "CONFIG_FIT_SIGNATURE must be enabled for full secure boot" ".config"
    grep -qx 'CONFIG_SPL_FIT_SIGNATURE=y' .config || exit_with_error "CONFIG_SPL_FIT_SIGNATURE must be enabled for full secure boot" ".config"
    grep -Eq 'rsa(2048|4096)' u-boot.its || exit_with_error "U-Boot ITS has no supported RSA signature node" "u-boot.its"

    # With CONFIG_FIT_ENABLE_RSASSA_PSS_SUPPORT the generated U-Boot ITS is
    # signed with padding = "pss", and the SPL/U-Boot verifiers in this tree
    # only accept maximum-salt PSS signatures.  A tree-built mkimage linked
    # against OpenSSL >= 3.5 signs with digest-length salt, which SPL rejects
    # on the device.  Sign with the Rockchip prebuilt mkimage instead: it is
    # statically linked, so its maximum-salt behaviour is frozen into the
    # binary regardless of the build container's OpenSSL.  The tree-built
    # fit_check_sign below uses the same verify code as SPL, so any salt
    # drift in the signing tool fails the build instead of the boot.
    rk_secure_boot_resolve_mkimage

    # The USBPLUG postprocess rebuilds host tools with its temporary config,
    # leaving mkimage without FIT-signature support. Restore the host tools
    # from the final secure U-Boot configuration before signing the FIT.
    if tools/mkimage -h 2>&1 | grep -q 'Signing / verified boot not supported'; then
        make -B tools-only || exit_with_error "Failed to rebuild FIT-signing U-Boot host tools" "${PWD}/tools"
    fi

    fit_padding=0x1000
    grep -qx 'CONFIG_FIT_ENABLE_RSA4096_SUPPORT=y' .config && fit_padding=0x1200
    mkdir -p fit || exit_with_error "Failed to create FIT output directory" "${PWD}/fit"
    rm -f fit/uboot.itb data2sign.bin

    # boot.itb is signed later with -K u-boot.dtb.  Inject that key before
    # generating the final U-Boot FIT so the DTB embedded in u-boot.itb is the
    # same trusted DTB used by the running U-Boot instance.
    if ! fdtget -l u-boot.dtb /signature >/dev/null 2>&1; then
        "${RK_SECURE_BOOT_MKIMAGE}" -f u-boot.its -k "${keys_dir}" -K u-boot.dtb \
            -E -p "${fit_padding}" -r fit/uboot.itb ||
            exit_with_error "Failed to inject the boot FIT public key into U-Boot DTB" "u-boot.dtb"
    fi
    "${RK_SECURE_BOOT_MKIMAGE}" -f u-boot.its -k "${keys_dir}" -K spl/u-boot-spl.dtb \
        -E -p "${fit_padding}" -r fit/uboot.itb ||
        exit_with_error "Failed to sign Armbian-built U-Boot FIT" "${platform}"

    fdtget -l spl/u-boot-spl.dtb /signature 2>/dev/null | grep -qx 'key-dev' ||
        exit_with_error "FIT public key was not embedded in SPL DTB" "spl/u-boot-spl.dtb"

    fdtget -p fit/uboot.itb /configurations/conf/signature 2>/dev/null | grep -qx 'value' ||
        exit_with_error "U-Boot FIT configuration was not signed" "fit/uboot.itb"

    signed_fit="fit/uboot.itb"
    [[ -f "${signed_fit}" ]] || exit_with_error "Signed U-Boot FIT missing" "${signed_fit}"
    install -m 0644 "${signed_fit}" u-boot.itb || exit_with_error "Failed to install signed U-Boot FIT" "u-boot.itb"
    tools/fit_check_sign -f u-boot.itb -k spl/u-boot-spl.dtb -s ||
        exit_with_error "Signed U-Boot FIT verification failed" "u-boot.itb"

    rk_secure_boot_minimize_spl_fit_key
    rk_secure_boot_repack_signed_spl
    rk_secure_boot_rebuild_idbloader
    rk_secure_boot_sign_loader_artifacts "${rk_sign_tool}" "${platform}" "${keys_dir}"
    rk_secure_boot_rebuild_spi_loader
    display_alert "secure-uboot" "Signed U-Boot FIT, embedded SPL key, and loader artifacts" "info"
}

function rk_secure_boot_prepare_uboot_tree() {
    # Goal: Generate keys required for FIT signing before U-Boot configuration, plus an optional system encryption key.
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    if [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]; then
        enable_optee_bootchain_bl32_fit_node
    fi

    if [[ "${DISABLE_FIT_KEY_GEN}" == "yes" ]]; then
        if rk_full_secure_boot_enabled; then
            exit_with_error "DISABLE_FIT_KEY_GEN cannot be used with full secure boot" "RK_SECURE_UBOOT_ENABLE=yes requires a FIT signing key"
        fi
        return 0
    fi

    local uboot_workdir rkbin_root rkbin_dir rk_sign_tool keys_dir persistent_keys_dir
    uboot_workdir="$(pwd)"  # Current directory is the U-Boot source tree
    keys_dir="${uboot_workdir}/keys"

    # Prefer UBOOT_DIR if user explicitly set it
    if [[ -n "${UBOOT_DIR}" ]]; then
        uboot_workdir="${UBOOT_DIR}"
        keys_dir="${UBOOT_DIR}/keys"
    fi

    # A caller may provide a persistent signing-key directory. This is useful
    # when an SPI-only build and a separately built OS FIT must retain one
    # signing identity. With no directory supplied, preserve the upstream
    # behavior: reuse worktree keys when present or generate a new key pair.
    persistent_keys_dir="${UBOOT_FIT_KEYS_BACKUP_DIR:-}"

    rk_secure_boot_stage_uboot_fit_generator "${uboot_workdir}"

    rkbin_root="$(rk_sdk_rkbin_root)"
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    display_alert "secure-uboot" "rkbin root: ${rkbin_root}" "debug"
    display_alert "secure-uboot" "platform rkbin: ${rkbin_dir:-<not found>}" "debug"
    rk_secure_boot_prepare_tee_bin "${uboot_workdir}"

    # Find rk_sign_tool executable (prefer PATH)
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_dir}" && -x "${rkbin_dir}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_dir}/tools/rk_sign_tool"
    fi
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_root}" && -x "${rkbin_root}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_root}/tools/rk_sign_tool"
    fi

    if [[ -z "${rk_sign_tool}" ]]; then
        if rk_full_secure_boot_enabled; then
            exit_with_error "rk_sign_tool not found for full secure boot" "Cannot generate or sign FIT key material"
        fi
        display_alert "secure-uboot" "rk_sign_tool not found, skipping FIT key generation" "warn"
        return 0
    fi

    mkdir -p "${keys_dir}" || { display_alert "secure-uboot" "Cannot create directory ${keys_dir}" "err"; return 1; }

    if [[ -n "${persistent_keys_dir}" ]]; then
        [[ -f "${persistent_keys_dir}/private_key.pem" ]] ||
            exit_with_error "FIT signing private key missing" "${persistent_keys_dir}/private_key.pem"
        # mkimage signs with the key's actual bit length, but the ITS template
        # hardcodes algo="sha256,rsa2048" and the SPL/U-Boot verifiers run with
        # rsa,num-bits=2048.  An RSA-4096 key yields a 512-byte signature that
        # fit_check_sign reads as a 256-byte EM and rejects with
        # "invalid pss padding (0xbc is missing)".  Refuse non-2048 keys here so
        # the build fails fast with a clear message instead of 26 matrix legs
        # deep in the FIT self-check.
        local key_bits
        key_bits=$(openssl rsa -in "${persistent_keys_dir}/private_key.pem" -text -noout 2>/dev/null |
            grep -oE 'Private-Key: \([0-9]+ bit' | grep -oE '[0-9]+' | head -1)
        [[ "${key_bits}" == "2048" ]] ||
            exit_with_error "FIT signing private key must be RSA-2048" \
                "${persistent_keys_dir}/private_key.pem is RSA-${key_bits:-unparseable}"
        display_alert "secure-uboot" "Restoring caller-supplied FIT signing keys" "${persistent_keys_dir}" "info"
        (
            cd "${keys_dir}" || exit 1
            install -m 0600 "${persistent_keys_dir}/private_key.pem" private_key.pem || exit 1
            if [[ -f "${persistent_keys_dir}/public_key.pem" ]]; then
                install -m 0644 "${persistent_keys_dir}/public_key.pem" public_key.pem || exit 1
            else
                openssl pkey -in private_key.pem -pubout -out public_key.pem || exit 1
                chmod 0644 public_key.pem
            fi
            if [[ -f "${persistent_keys_dir}/dev.crt" ]]; then
                install -m 0644 "${persistent_keys_dir}/dev.crt" dev.crt || exit 1
            else
                openssl req -batch -new -x509 -key private_key.pem -out dev.crt -subj "/CN=Armbian FIT Key/" || exit 1
                chmod 0644 dev.crt
            fi
            ln -sf private_key.pem dev.key
            ln -sf public_key.pem dev.pubkey
        )
        display_alert "secure-uboot" "Caller-supplied FIT keys restored: ${keys_dir}" "info"
    elif [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.crt" ]]; then
        display_alert "secure-uboot" "Existing keys detected, skipping generation (${keys_dir})" "info"
    else
        display_alert "secure-uboot" "Generating initial key pair using rk_sign_tool" "info"
        (
            cd "${keys_dir}" || exit 1
            "${rk_sign_tool}" kk --bits 2048 --out ./ || exit_with_error "rk_sign_tool key generation failed" "${rk_sign_tool}"
            ln -rsf private_key.pem dev.key
            ln -rsf public_key.pem dev.pubkey
            openssl req -batch -new -x509 -key dev.key -out dev.crt -subj "/CN=Armbian FIT Key/" || exit_with_error "Failed to generate self-signed certificate" "dev.crt"
            openssl rand -hex 32 > system_enc_key || exit_with_error "Failed to generate system_enc_key" "system_enc_key"
        )
        display_alert "secure-uboot" "FIT keys generated: ${keys_dir}" "info"
    fi

    # Export path for later stages/packaging
    export UBOOT_FIT_KEYS_DIR="${keys_dir}"
}
