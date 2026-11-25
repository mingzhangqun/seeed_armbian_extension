# Boot-partition slimming (v0.8 patch #7): drop initrd.img-* from /boot.
# U-Boot loads uInitrd-* (mkimage-wrapped), never the raw file, and
# rk_secure_boot_find_ramdisk prefers uInitrd-*, so secure FIT packaging
# survives the prune. Runs at 899, just before rescue-artifacts (900), so the
# rescue payload and the live /boot agree on the file set.

function pre_umount_final_image__899_slim_initrd_img() {
    local boot_dir="${MOUNT}/boot"

    # Nothing to do if the slimmed layout is already in effect.
    compgen -G "${boot_dir}/initrd.img-"* > /dev/null || return 0

    # Hard requirement: uInitrd-* must exist for the same kernel version,
    # otherwise U-Boot has no initramfs to load after the prune.
    local img ver
    for img in "${boot_dir}"/initrd.img-*; do
        [[ -e "${img}" ]] || continue
        ver="$(basename "${img}" | sed 's/^initrd\.img-//')"
        if [[ ! -e "${boot_dir}/uInitrd-${ver}" && ! -e "${boot_dir}/uInitrd" ]]; then
            exit_with_error "Boot slim" \
                "refusing to drop initrd.img-${ver}: no uInitrd-${ver} or uInitrd fallback present"
        fi
    done

    local removed=()
    for img in "${boot_dir}"/initrd.img-*; do
        [[ -e "${img}" ]] || continue
        removed+=("$(basename "${img}")")
        rm -f "${img}" ||
            exit_with_error "Boot slim" "failed to remove ${img}"
    done

    ((${#removed[@]})) || return 0
    display_alert "Boot slim" "removed initrd.img-* from /boot: ${removed[*]}" "info"
    sync
}
