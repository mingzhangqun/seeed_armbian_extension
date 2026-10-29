# Rescue boot assets (v0.8 patch #1): the independent rescue kernel,
# initrd and dtb that live in boot/recovery/ and are loaded directly by
# ota_rescue_boot (ext4load + booti, no container).
#
# Ordering: runs as pre_umount_final_image__900, BEFORE the payload package
# hook (901). The package side stages the boot partition with recovery/
# excluded, so the rescuer never ships inside an OTA package and can never
# be deleted by one (design section 1: OTA 禁止删除或覆盖 boot/recovery/).

function ota_rescue_artifacts_resolve_dtb() {
    local boot_dir="$1"
    local fdtfile fdt_path

    fdtfile="$(sed -n 's/^fdtfile=//p' "${boot_dir}/armbianEnv.txt" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ -n "${fdtfile}" ]]; then
        fdt_path="${boot_dir}/dtb/${fdtfile}"
        if [[ -f "${fdt_path}" ]]; then
            printf '%s\n' "${fdt_path}"
            return 0
        fi
    fi

    # fallback: the pruned boot partition keeps only the board's dtbs
    fdt_path="$(find "${boot_dir}/dtb" -type f -name '*.dtb' 2>/dev/null | LC_ALL=C sort | head -n1)"
    [[ -n "${fdt_path}" ]] && printf '%s\n' "${fdt_path}"
    return $?
}

function pre_umount_final_image__900_install_recovery_rescue() {
    # Secure/raw-FIT layouts boot a signed FIT from a raw partition; the
    # ext4 rescue directory is plain-mode only (Phase 2 owns the FIT design).
    ota_raw_boot_enabled && {
        display_alert "Recovery rescue assets" "raw-FIT mode; ext4 rescue deferred to Phase 2" "info"
        return 0
    }

    local boot_dir="${MOUNT}/boot"
    local rescue_dir="${boot_dir}/recovery"
    local image initrd dtb rescue_id

    [[ -f "${boot_dir}/Image" ]] ||
        exit_with_error "Recovery rescue assets" "missing ${boot_dir}/Image"
    [[ -f "${boot_dir}/uInitrd" ]] ||
        exit_with_error "Recovery rescue assets" "missing ${boot_dir}/uInitrd (same-build initrd is a hard requirement)"

    dtb="$(ota_rescue_artifacts_resolve_dtb "${boot_dir}")" ||
        exit_with_error "Recovery rescue assets" "cannot resolve the board dtb under ${boot_dir}/dtb"

    display_alert "Recovery rescue assets" "Image + uInitrd + $(basename "${dtb}") -> boot/recovery/" "info"

    mkdir -p "${rescue_dir}"
    cp "${boot_dir}/Image" "${rescue_dir}/Image" ||
        exit_with_error "Recovery rescue assets" "failed to copy Image"
    cp "${boot_dir}/uInitrd" "${rescue_dir}/uInitrd" ||
        exit_with_error "Recovery rescue assets" "failed to copy uInitrd"
    cp "${dtb}" "${rescue_dir}/board.dtb" ||
        exit_with_error "Recovery rescue assets" "failed to copy board dtb"

    # Rescue artifact identity (build record only; not part of the OTA
    # payload identity -- the rescue set is never updated by OTA).
    rescue_id="$(
        {
            sha256sum "${rescue_dir}/Image"
            sha256sum "${rescue_dir}/uInitrd"
            sha256sum "${rescue_dir}/board.dtb"
        } | sha256sum | awk '{print $1}'
    )"
    printf '%s\n' "${rescue_id}" > "${rescue_dir}/payload-id"

    sync
    display_alert "Recovery rescue assets" "installed, artifact id ${rescue_id:0:16}" "info"
}
