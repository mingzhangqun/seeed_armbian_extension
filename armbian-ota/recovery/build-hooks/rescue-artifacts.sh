# Rescue boot assets (v0.8 patch #1): the independent rescue kernel,
# initrd and dtb that U-Boot loads directly (no container).
#
# Two flavors, one goal -- a boot path that never depends on the rootfs:
#   ext4 boot partition (plain/auto-decrypt): Image/uInitrd/board.dtb in
#     boot/recovery/, loaded by ota_rescue_boot_fs (ext4load + booti)
#   raw-FIT layout (secure boot): the same signed boot.itb flashed to the
#     dedicated PARTLABEL=recovery partition, booted by ota_rescue_boot_fit
#     (vendor boot_fit; FIT signature verification included). The FIT's
#     ramdisk component is the same-build initramfs, so the rescue boots
#     straight into the 99-ota-apply Rescue role.
#
# Ordering: runs as pre_umount_final_image__900, BEFORE the payload package
# hook (901). The secure FIT hook (package_fit) sorts at 500 -- before every
# numbered hook -- so the signed boot.itb already exists when this hook runs.
# The package side stages the boot partition with recovery/ excluded, so the
# rescuer never ships inside an OTA package and can never be deleted by one
# (design section 1: OTA 禁止删除或覆盖 boot/recovery/ 及 recovery 分区).

# Canonical signed kernel FIT produced by rk_secure_boot_package_final_fit
# (secure-boot-image.sh); the OTA package hook reads the same path.
function ota_rescue_fit_image() {
    echo "${RK_SECURE_BOOT_FIT_IMAGE:-${SRC}/cache/sources/${BOOTSOURCEDIR}/fit/boot.itb}"
}

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

# Stamp the layout flavor into the rootfs so the runtime health service can
# branch without probing block devices (plain recovery stamps "filesystem").
# Hard failure, not a warning: the Rescue success-reconciliation treats the
# stamp as the deciding input on raw-FIT devices (HAS_BOOT_PART=0), so a
# warn-only write could ship a rootfs whose next reconciliation wedges in
# rescue_shell with an unclearable STATUS=success.
function ota_rescue_stamp_boot_mode() {
    local mode="$1"
    local stamp_dir="${MOUNT}/usr/share/armbian-ota"
    local stamp_file="${stamp_dir}/boot-mode"

    mkdir -p "${stamp_dir}" ||
        exit_with_error "Recovery rescue assets" "cannot create ${stamp_dir} for boot-mode stamp"
    printf '%s\n' "${mode}" > "${stamp_file}" ||
        exit_with_error "Recovery rescue assets" "failed to stamp boot-mode=${mode}"
}

# Resolve the rescue partition from the loop's partition table by
# PARTLABEL. The RECOVERY_RESCUE_PART_INDEX variable set by the partition
# hook does not survive across hook rounds (same host/container split that
# hit BOOT_RAW_MODE); parsing the live table needs no cross-hook state.
# Emits "<node> <start-sector> <size-in-sectors>" -- the sector is what the
# flash uses (this stage's loop is attached without -P and carries no
# partition device nodes), the size feeds the FIT-vs-partition bound check.
function ota_rescue_recovery_partition() {
    sfdisk -J "${LOOP}" 2>/dev/null | python3 -c '
import json, sys
try:
    table = json.load(sys.stdin)["partitiontable"]
except Exception:
    sys.exit(1)
for p in table.get("partitions", []):
    if p.get("name") == "recovery":
        print(p["node"], p["start"], p["size"])
        break
'
}

function ota_rescue_flash_fit_partition() {
    local fit_image rescue_dev rescue_start rescue_sectors fit_size magic

    fit_image="$(ota_rescue_fit_image)"
    read -r rescue_dev rescue_start rescue_sectors <<< "$(ota_rescue_recovery_partition)"
    [[ -n "${rescue_start}" ]] ||
        exit_with_error "Recovery rescue assets" "rescue partition not found on ${LOOP} by PARTLABEL=recovery"
    [[ -f "${fit_image}" ]] ||
        exit_with_error "Recovery rescue assets" "signed FIT missing for raw rescue: ${fit_image}"

    # Same bound the device-side write_raw_boot_itb enforces: without it a
    # small OTA_BOOT_SIZE plus a larger FIT dd's straight past the rescue
    # partition into the following security/rootfs partition, and the
    # 4-byte magic readback still passes.
    fit_size="$(stat -c%s "${fit_image}")"
    if [[ -n "${rescue_sectors}" && "${fit_size}" -gt $((rescue_sectors * 512)) ]]; then
        exit_with_error "Recovery rescue assets" "signed FIT (${fit_size} bytes) exceeds the rescue partition ($((rescue_sectors * 512)) bytes); raise OTA_BOOT_SIZE"
    fi

    display_alert "Recovery rescue assets" "flashing $(basename "${fit_image}") -> ${LOOP} @ sector ${rescue_start} (${rescue_dev})" "info"
    dd if="${fit_image}" of="${LOOP}" bs=512 seek="${rescue_start}" conv=notrunc status=none ||
        exit_with_error "Recovery rescue assets" "failed to flash rescue FIT at sector ${rescue_start}"
    sync

    # read back the FIT magic: d00dfeed (FDT magic, first 4 bytes big-endian)
    magic="$(dd if="${LOOP}" bs=512 skip="${rescue_start}" status=none | od -An -tx1 -N4 | tr -d ' \n')"
    [[ "${magic}" = "d00dfeed" ]] ||
        exit_with_error "Recovery rescue assets" "rescue partition readback is not a FIT image (magic=${magic:-none})"

    display_alert "Recovery rescue assets" "rescue FIT flashed and verified on ${rescue_dev}" "info"
}

function pre_umount_final_image__900_install_recovery_rescue() {
    if ota_raw_boot_enabled; then
        # Secure/raw-FIT: rescue = same signed FIT on the dedicated
        # PARTLABEL=recovery partition (booted via ota_rescue_boot_fit).
        ota_rescue_flash_fit_partition
        ota_rescue_stamp_boot_mode "raw-fit"
        return 0
    fi

    local boot_dir="${MOUNT}/boot"
    local rescue_dir="${boot_dir}/recovery"
    local image initrd dtb

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

    # No identity file lives here: the rescue set is frozen at image build
    # and never updated by OTA, and a self-stored digest proves nothing (it
    # can be tampered with alongside the assets). Verify against the build
    # log or the original image when in doubt.

    sync
    ota_rescue_stamp_boot_mode "filesystem"
    display_alert "Recovery rescue assets" "installed (Image + uInitrd + board.dtb)" "info"
}
