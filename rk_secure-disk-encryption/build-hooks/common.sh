# Common RK build hook helpers
function rk_run_host_command() {
    if [[ "$(type -t run_host_command_logged || true)" == "function" ]]; then
        run_host_command_logged "$@"
    else
        "$@"
    fi
}
# Rename a live shell function so a wrapper can replace the original name.
function rk_wrap_function() {
    local original="$1" new_name="$2"

    eval "$(declare -f "${original}" | sed "1s/^${original} /${new_name} /")"
}

function rk_fetch_sdk_tools() {
    local sdk_tools_url="${RKSDK_TOOLS_GIT_URL:-${RKBIN_GIT_URL:-"https://github.com/Seeed-Studio/rockchip_sdk_tools.git"}}"

    fetch_from_repo "${sdk_tools_url}" "rockchip_sdk_tools" "branch:${RKSDK_TOOLS_BRANCH:-"main"}"
}

function rk_sdk_tools_root() {
    echo "${SRC}/cache/sources/rockchip_sdk_tools"
}

function rk_sdk_rkbin_root() {
    echo "$(rk_sdk_tools_root)/rkbin"
}

function rk_ensure_sdk_tools() {
    local alert_label="${1:-rockchip-sdk-tools}"
    local sdk_tools_root
    sdk_tools_root="$(rk_sdk_tools_root)"

    if [[ ! -d "${sdk_tools_root}" ]]; then
        display_alert "${alert_label}" "rockchip_sdk_tools source directory not found, downloading" "info"
        rk_fetch_sdk_tools
    fi
}
function rk_full_secure_boot_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]]
}

function rk_optee_bootchain_enabled() {
    rk_full_secure_boot_enabled || [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]
}

function rk_autodecrypt_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function rk_autodecrypt_nonsecure_mode_enabled() {
    rk_autodecrypt_enabled && ! rk_full_secure_boot_enabled
}

function rk_autodecrypt_fit_boot_required() {
    rk_full_secure_boot_enabled ||
        { rk_autodecrypt_enabled && [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; }
}
function rk_platform_from_name() {
    local name
    name="$(echo "$*" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')"

    case "${name}" in
        *rk3576*|*3576*) echo "rk3576" ;;
        *rk3588*|*3588*) echo "rk3588" ;;
        *) echo "unknown" ;;
    esac
}

function rk_default_vendor_board() {
    local platform="$1"

    case "${platform}" in
        rk3576|rk3588) echo "recomputer-${platform}-devkit" ;;
        *) echo "unknown" ;;
    esac
}

function rk_detect_platform() {
    local platform

    platform="$(rk_platform_from_name "${BOOT_SOC:-}")"
    if [[ "${platform}" != "unknown" ]]; then
        echo "${platform}"
        return 0
    fi

    rk_platform_from_name "${BOARD_NAME:-${BOARD:-}}"
}

function rk_detect_vendor_board() {
    rk_default_vendor_board "$(rk_detect_platform)"
}
function rk_resolve_extension_dir() {
    local required_subdir="$1"
    local script_dir candidate
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    for candidate in \
        "${script_dir}" \
        "${SRC}/extensions/seeed_armbian_extension/rk_secure-disk-encryption" \
        "${SRC}/extensions/rk_secure-disk-encryption"; do
        if [[ -d "${candidate}/${required_subdir}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    echo "${script_dir}"
}

# Resolve a file shipped in this extension: locate the extension root via
# probe_subdir, then require relpath under it.
function rk_extension_file_path() {
    local probe_subdir="$1"
    local relpath="$2"
    local candidate

    candidate="$(rk_resolve_extension_dir "${probe_subdir}")/${relpath}"
    [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }

    return 1
}

function rk_secure_uboot_fit_generator_path() {
    rk_extension_file_path "u-boot/fit-generator" "u-boot/fit-generator/make_fit_atf_optee.sh"
}

function rk_secure_kernel_fit_template_path() {
    local platform
    platform="$(rk_detect_platform)"
    [[ "${platform}" != "unknown" ]] || return 1
    rk_extension_file_path "u-boot/fit-kernel" "u-boot/fit-kernel/${platform}_fit_kernel.its"
}

function rk_secure_uboot_config_fragment_path() {
    local platform
    platform="$(rk_detect_platform)"
    [[ "${platform}" != "unknown" ]] || return 1
    rk_extension_file_path "u-boot/fragments" "u-boot/fragments/${platform}-secure-autodecrypt.config"
}
function rk_apply_kconfig_fragment() {
    local _config_tool="$1"
    local fragment="$2"
    shift 2

    local target_config=".config"
    local merge_config="scripts/kconfig/merge_config.sh"
    local line

    [[ -f "${fragment}" ]] || exit_with_error "Kconfig fragment missing" "${fragment}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                [[ $# -ge 2 ]] || exit_with_error "Missing --file value for Kconfig fragment merge" "${fragment}"
                target_config="$2"
                shift 2
                ;;
            *)
                exit_with_error "Unsupported Kconfig fragment merge argument" "$1"
                ;;
        esac
    done

    [[ -f "${target_config}" ]] || exit_with_error "Kconfig target missing; cannot apply fragment" "${target_config}"
    [[ -x "${merge_config}" ]] || exit_with_error "merge_config.sh missing; cannot apply Kconfig fragment" "${merge_config}"

    KCONFIG_CONFIG="${target_config}" rk_run_host_command "${merge_config}" -m "${target_config}" "${fragment}" ||
        exit_with_error "Kconfig fragment merge failed" "${fragment}"

    # Re-resolve Kconfig dependencies before verifying. merge_config -m only
    # edits the text: a fragment line that a hidden "select" overrides (e.g.
    # DISTRO_DEFAULTS selects CMD_BOOTI on ARM64) would pass the textual
    # check below and then silently re-enable at the real build's syncconfig.
    # olddefconfig settles the same .config the build will use, so the
    # verification below sees the final values.
    KCONFIG_CONFIG="${target_config}" rk_run_host_command make olddefconfig ||
        exit_with_error "Kconfig olddefconfig failed after fragment merge" "${fragment}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^CONFIG_[A-Za-z0-9_]+= ]] || [[ "${line}" =~ ^#\ CONFIG_[A-Za-z0-9_]+\ is\ not\ set$ ]] || continue
        grep -Fxq "${line}" "${target_config}" ||
            exit_with_error "Kconfig fragment merge verification failed" "missing '${line}' in ${target_config}"
    done < "${fragment}"
}
