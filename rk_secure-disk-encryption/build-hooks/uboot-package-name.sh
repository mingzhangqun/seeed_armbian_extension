# Keep full secure boot in a separate Debian package namespace without
# modifying the Armbian build tree.  Armbian currently exposes no U-Boot
# artifact package-name hook, so retain and wrap the two affected functions.

if [[ "$(type -t artifact_uboot_prepare_version || true)" != "function" ]] || \
    [[ "$(type -t dpkg_deb_build || true)" != "function" ]]; then
    exit_with_error "Armbian U-Boot package helpers are unavailable" "cannot apply the secure U-Boot package name"
fi

rk_wrap_function artifact_uboot_prepare_version seeed_upstream_artifact_uboot_prepare_version
rk_wrap_function dpkg_deb_build seeed_upstream_dpkg_deb_build

function artifact_uboot_prepare_version() {
    seeed_upstream_artifact_uboot_prepare_version "$@"

    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    artifact_map_packages["uboot"]="${artifact_map_packages[uboot]}-secure"
    artifact_name="${artifact_name}-secure"
}

function dpkg_deb_build() {
    local package_directory="$1"
    local artifact_deb_id="$2"
    local package_name

    if [[ "${artifact_deb_id}" == "uboot" ]] && rk_full_secure_boot_enabled; then
        package_name="${artifact_map_packages[uboot]:-}"
        [[ -n "${package_name}" ]] || exit_with_error "Secure U-Boot package name is unavailable"
        sed -i "s/^Package: .*/Package: ${package_name}/" "${package_directory}/DEBIAN/control"
    fi

    seeed_upstream_dpkg_deb_build "$@"
}
