# Build-time U-Boot environment prefill for OTA images (A/B and recovery).
#
# Prefill valid env blobs so every flash boots the token-carrying bootcmd.

OTA_UBOOT_ENV_OFFSET_HEX="0x3f8000"       # CONFIG_ENV_OFFSET (env/Kconfig, ARCH_ROCKCHIP)
OTA_UBOOT_ENV_REDUND_OFFSET_HEX="0x3f0000" # CONFIG_ENV_OFFSET_REDUND (redundant copy)
OTA_UBOOT_ENV_SIZE_HEX="0x8000"           # CONFIG_ENV_SIZE
# rk3576/rk3588: redundant layout; other boards need the single-copy blob.
OTA_UBOOT_ENV_REDUNDANT=0
case "${BOOT_SOC:-}" in
    rk3576 | rk3588) OTA_UBOOT_ENV_REDUNDANT=1 ;;
esac

# mkenvimage discovery: the build container ships u-boot-tools, but fall back
# to the binary produced by any local U-Boot compilation so image-only builds
# work on bare hosts too.
function ota_uboot_env_prefill_mkenvimage() {
    local candidate

    if command -v mkenvimage >/dev/null 2>&1; then
        command -v mkenvimage
        return 0
    fi

    for candidate in "${SRC}"/cache/sources/u-boot-worktree/*/*/tools/mkenvimage; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

# Assemble the final env text for the image being built. AB images reuse the
# merged initial env written into the rootfs by pre_update_initramfs__895;
# recovery images merge the compiled default env with a bootcmd override that
# prefixes the same armbian.bootdev token the AB bootcmd carries.
function ota_uboot_env_prefill_compose() {
    local final_env="$1"
    local default_env="${UBOOT_CHROOT_DIR}/u-boot-default.env"
    local src_env bootcmd_value override_env raw_override_env

    if [[ "${AB_PART_OTA:-}" == "yes" ]]; then
        src_env="${MOUNT}/etc/u-boot-initial-env"
        [[ -f "${src_env}" ]] ||
            exit_with_error "A/B initial env missing" "${src_env} not generated"
        grep -q '^bootcmd=.*armbian\.bootdev' "${src_env}" ||
            exit_with_error "A/B initial env lacks bootdev token" "${src_env}"

        local mode_override_env
        mode_override_env="$(mktemp)" || exit_with_error "mktemp failed"
        if ota_raw_boot_enabled; then
            # Raw-FIT images must take the bootcmd's raw-fit branch from the
            # very first boot. The else-branch runs distro_bootcmd first, and
            # its per-device boot_android calls repoint android_get_bootdev()
            # at whatever device was scanned last (the SPI mtd on boards with
            # NOR flash), so the trailing boot_fit then searches the wrong
            # device and dies with "No boot partition" (RK3588 SD boot,
            # 2026-09-03). ota-init only sets this mode after a bootstrapped
            # first boot, which never happens without this injection.
            printf 'ab_boot_mode=raw-fit\n' > "${mode_override_env}"
        else
            # Plain A/B: stamp the fs branch; plain FIT boots stay a manual console action.
            printf 'ab_boot_mode=filesystem\n' > "${mode_override_env}"
        fi
        ota_ab_merge_uboot_env_files "${final_env}" "${src_env}" "${mode_override_env}"
        rm -f "${mode_override_env}"
        return 0
    fi

    [[ -f "${default_env}" ]] ||
        exit_with_error "U-Boot default env not packaged" "${default_env} missing; rebuild u-boot (./seeed-build.sh --uboot) so the deb carries u-boot-default.env"

    # v0.8 routing env (design section 3.2): transaction flags + the p1
    # anchored boot pair + a bootcmd that (a) saves ota_boot_next=recovery
    # BEFORE booting a candidate, (b) routes to Rescue on every normal
    # return, (c) never scans external media. The Seeed boot.scr already
    # carries the armbian.bootdev tokens in its own bootargs, and the rescue
    # branches inject them directly, so no bootargs prefixing is needed here.
    routing_env="$(mktemp)" || exit_with_error "mktemp failed"
    # Plain uses ext4 only; FIT is never a plain fallback.
    local rescue_root="LABEL=armbi_root" normal_boot rescue_boot fit_normal fit_rescue
    if ota_raw_boot_enabled; then
        normal_boot='run ota_normal_boot_fit'
        rescue_boot='run ota_rescue_boot_fit'
        fit_normal='setenv boot_fit_part boot; env set bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum}"; boot_fit'
        fit_rescue='setenv boot_fit_part recovery; env set bootargs "${bootargs} armbian.bootdev=${devtype} armbian.bootdevnum=${devnum} armbian.ota_role=recovery"; boot_fit'
    else
        normal_boot='run ota_normal_boot_fs'
        rescue_boot='run ota_rescue_boot_fs || run distro_bootcmd'
        fit_normal='echo "PLAIN: raw FIT boot refused"'
        fit_rescue='echo "PLAIN: raw FIT boot refused"'
    fi
    if ota_encrypted_rootfs_enabled; then
        rescue_root="/dev/mapper/armbian-root"
    fi
    # The FIT DTB is the source of truth for configured console/root/extra
    # bootargs. Do not replace them with a second hardcoded copy: append only
    # the dynamic boot-disk tokens and the recovery role before boot_fit.
    {
        printf '%s\n' 'ota_in_progress=0'
        printf '%s\n' 'ota_boot_next=recovery'
        printf '%s\n' 'ota_normal_boot_fs=setenv prefix /; ext4load ${devtype} ${devnum}:1 ${scriptaddr} /boot.scr && source ${scriptaddr}'
        printf 'ota_normal_boot_fit=%s\n' "${fit_normal}"
        printf 'ota_normal_boot=%s\n' "${normal_boot}"
        printf '%s\n' "ota_rescue_boot_fs=ext4load \${devtype} \${devnum}:1 \${kernel_addr_r} /recovery/Image && ext4load \${devtype} \${devnum}:1 \${ramdisk_addr_r} /recovery/uInitrd && ext4load \${devtype} \${devnum}:1 \${fdt_addr_r} /recovery/board.dtb && setenv bootargs \"root=${rescue_root} rootwait rootfstype=ext4 console=ttyFIQ0,1500000n8 armbian.bootdev=\${devtype} armbian.bootdevnum=\${devnum} armbian.ota_role=recovery\" && booti \${kernel_addr_r} \${ramdisk_addr_r} \${fdt_addr_r}"
        printf 'ota_rescue_boot_fit=%s\n' "${fit_rescue}"
        printf 'ota_rescue_boot=%s\n' "${rescue_boot}"
        printf '%s\n' 'bootcmd=if test -z "${devtype}"; then run rkimg_bootdev; fi; if test "${ota_in_progress}" = "1"; then if test "${ota_boot_next}" = "normal"; then setenv ota_boot_next recovery; if saveenv; then run ota_normal_boot; fi; run ota_rescue_boot; else run ota_rescue_boot; fi; else run ota_normal_boot; run ota_rescue_boot; fi'
    } > "${routing_env}"

    ota_ab_merge_uboot_env_files "${final_env}" "${default_env}" "${routing_env}"
    rm -f "${routing_env}"
}

# Validate that the env area fits between the u-boot loader blob and
# partition 1. Only the blob starting at sector 64 can reach the env gap
# below 4 MiB: secure images split the loader (idbloader.img at sector 64 +
# u-boot.itb at sector 16384) and the FIT lands inside partition 1 by
# design, far beyond the env area.
function ota_uboot_env_prefill_assert_layout() {
    local offset_hex="$1"
    local offset=$((offset_hex))
    local size=$((OTA_UBOOT_ENV_SIZE_HEX))
    local env_end_sector=$(((offset + size) / 512))
    local first_part_start uboot_end sector64_blob candidate

    ((offset % 512 == 0 && size % 512 == 0)) ||
        exit_with_error "Env geometry not sector-aligned" "offset=${offset_hex} size=${OTA_UBOOT_ENV_SIZE_HEX}"

    first_part_start="$(sfdisk -J "${LOOP}" 2>/dev/null |
        jq '.partitiontable.partitions | map(.start) | min')" ||
        exit_with_error "Cannot parse partition table" "sfdisk -J ${LOOP}"

    [[ "${first_part_start}" =~ ^[0-9]+$ ]] &&
        ((first_part_start >= env_end_sector)) ||
        exit_with_error "Env area overlaps partition 1" "env ends at sector ${env_end_sector}, partition 1 starts at ${first_part_start}"

    for candidate in u-boot-rockchip.bin rksd_loader.img idbloader.img; do
        if [[ -f "${UBOOT_CHROOT_DIR}/${candidate}" ]]; then
            sector64_blob="${UBOOT_CHROOT_DIR}/${candidate}"
            break
        fi
    done
    [[ -n "${sector64_blob}" ]] ||
        exit_with_error "u-boot blob not found for overlap check" "no known loader blob in ${UBOOT_CHROOT_DIR}"
    uboot_end=$((64 * 512 + $(stat -c%s "${sector64_blob}")))
    ((uboot_end <= offset)) ||
        exit_with_error "u-boot blob overlaps env area" "$(basename "${sector64_blob}") ends at ${uboot_end}, env starts at ${offset}"
}

# Read the blob back from the image and verify CRC + token, then log the
# bootcmd that will run on first boot.
function ota_uboot_env_prefill_verify() {
    local loop="$1" seek_sector="$2" size="$3"
    local env_info data_skip

    # Redundant layout: CRC(4) + flags(1) + data; single-copy: CRC(4) + data.
    [[ "${OTA_UBOOT_ENV_REDUNDANT}" == "1" ]] && data_skip=5 || data_skip=4
    env_info="$(dd if="${loop}" bs=512 skip="${seek_sector}" count="$((size / 512))" status=none |
        python3 -c "
import struct, sys, zlib
skip = ${data_skip}
blob = sys.stdin.buffer.read()
crc = struct.unpack('<I', blob[:4])[0]
if (zlib.crc32(blob[skip:]) & 0xFFFFFFFF) != crc:
    sys.exit('env blob CRC mismatch after write')
for entry in blob[skip:].split(b'\0'):
    if not entry:
        break
    print(entry.decode('utf-8', 'replace'))
")" || exit_with_error "Env blob readback failed" "${env_info}"
    # Verify the tokens the composed env actually carries.  A/B blobs anchor
    # on the armbian.bootdev bootcmd from /etc/u-boot-initial-env (plus the
    # raw-fit override on secure images); only recovery blobs carry the v0.8
    # transactional routing script.  Checking the recovery tokens on an A/B
    # blob always fails and kills every A/B leg at image assembly.
    if [[ "${AB_PART_OTA:-}" == "yes" ]]; then
        grep -q '^bootcmd=.*armbian\.bootdev' <<< "${env_info}" ||
            exit_with_error "Prefilled A/B env lacks bootdev bootcmd" "bootcmd not carried into blob"
        if ota_raw_boot_enabled; then
            grep -q '^ab_boot_mode=raw-fit' <<< "${env_info}" ||
                exit_with_error "Prefilled A/B env lacks raw-fit mode" "ab_boot_mode not carried into blob"
        else
            grep -q '^ab_boot_mode=filesystem' <<< "${env_info}" ||
                exit_with_error "Prefilled A/B env lacks filesystem mode" "ab_boot_mode not carried into blob"
        fi
    else
        grep -q '^ota_normal_boot_fit=' <<< "${env_info}" ||
            exit_with_error "Prefilled env lacks normal FIT boot script" "ota_normal_boot_fit not carried into blob"
        grep -q '^ota_rescue_boot_fs=' <<< "${env_info}" ||
            exit_with_error "Prefilled env lacks rescue boot script" "ota_rescue_boot_fs not carried into blob"
        grep -q '^ota_rescue_boot_fit=' <<< "${env_info}" ||
            exit_with_error "Prefilled env lacks rescue FIT boot script" "ota_rescue_boot_fit not carried into blob"
        if ota_raw_boot_enabled; then
            grep -qx 'ota_normal_boot=run ota_normal_boot_fit' <<< "${env_info}" ||
                exit_with_error "Prefilled env lacks secure FIT boot dispatcher" "ota_normal_boot not carried into blob"
            grep -qx 'ota_rescue_boot=run ota_rescue_boot_fit' <<< "${env_info}" ||
                exit_with_error "Prefilled env lacks secure rescue dispatcher" "ota_rescue_boot not carried into blob"
        else
            grep -q '^ota_normal_boot_fit=echo ' <<< "${env_info}" ||
                exit_with_error "Prefilled plain env has live FIT script" "ota_normal_boot_fit must be a refusal stub"
            grep -q '^ota_rescue_boot_fit=echo ' <<< "${env_info}" ||
                exit_with_error "Prefilled plain env has live FIT script" "ota_rescue_boot_fit must be a refusal stub"
            grep -qx 'ota_normal_boot=run ota_normal_boot_fs' <<< "${env_info}" ||
                exit_with_error "Prefilled env lacks plain normal boot dispatcher" "ota_normal_boot not carried into blob"
            grep -qx 'ota_rescue_boot=run ota_rescue_boot_fs || run distro_bootcmd' <<< "${env_info}" ||
                exit_with_error "Prefilled env lacks plain rescue dispatcher" "ota_rescue_boot not carried into blob"
        fi
        grep -q '^bootcmd=.*ota_in_progress' <<< "${env_info}" ||
            exit_with_error "Prefilled env lacks transactional bootcmd" "bootcmd not carried into blob"
    fi

    display_alert "OTA U-Boot env prefill" "$(grep '^bootcmd=' <<< "${env_info}")" "info"
}

function post_write_uboot_platform__910_prefill_uboot_env() {
    local offset=$((OTA_UBOOT_ENV_OFFSET_HEX))
    local redund_offset=$((OTA_UBOOT_ENV_REDUND_OFFSET_HEX))
    local size=$((OTA_UBOOT_ENV_SIZE_HEX))
    local seek_sector=$((offset / 512))
    local redund_seek_sector=$((redund_offset / 512))
    local mkenvimage_bin final_env blob mkenv_flags

    mkenvimage_bin="$(ota_uboot_env_prefill_mkenvimage)" ||
        exit_with_error "mkenvimage not found" "install u-boot-tools or run a u-boot build first"

    final_env="$(mktemp)" || exit_with_error "mktemp failed"
    blob="$(mktemp)" || exit_with_error "mktemp failed"

    ota_uboot_env_prefill_compose "${final_env}"
    ota_uboot_env_prefill_assert_layout "${OTA_UBOOT_ENV_OFFSET_HEX}"

    # -r = redundant layout (flags=1 both copies: deterministic primary on
    # first boot, first saveenv alternates). Single boards get 4B header.
    mkenv_flags=()
    if [[ "${OTA_UBOOT_ENV_REDUNDANT}" == "1" ]]; then
        mkenv_flags=(-r)
        ota_uboot_env_prefill_assert_layout "${OTA_UBOOT_ENV_REDUND_OFFSET_HEX}"
    fi
    "${mkenvimage_bin}" "${mkenv_flags[@]}" -s "${size}" -o "${blob}" "${final_env}" ||
        exit_with_error "mkenvimage failed" "${mkenvimage_bin} ${mkenv_flags[*]}"
    [[ "$(stat -c%s "${blob}")" == "${size}" ]] ||
        exit_with_error "Unexpected blob size" "$(stat -c%s "${blob}") != ${size}"

    dd if="${blob}" of="${LOOP}" bs=512 seek="${seek_sector}" conv=notrunc status=none ||
        exit_with_error "Failed to write env blob" "${LOOP} @ ${OTA_UBOOT_ENV_OFFSET_HEX}"
    if [[ "${OTA_UBOOT_ENV_REDUNDANT}" == "1" ]]; then
        dd if="${blob}" of="${LOOP}" bs=512 seek="${redund_seek_sector}" conv=notrunc status=none ||
            exit_with_error "Failed to write env blob" "${LOOP} @ ${OTA_UBOOT_ENV_REDUND_OFFSET_HEX}"
    fi
    sync

    ota_uboot_env_prefill_verify "${LOOP}" "${seek_sector}" "${size}"
    if [[ "${OTA_UBOOT_ENV_REDUNDANT}" == "1" ]]; then
        ota_uboot_env_prefill_verify "${LOOP}" "${redund_seek_sector}" "${size}"
    fi

    rm -f "${final_env}" "${blob}"
    if [[ "${OTA_UBOOT_ENV_REDUNDANT}" == "1" ]]; then
        display_alert "OTA U-Boot env prefill" "Wrote ${size} bytes at offsets ${OTA_UBOOT_ENV_OFFSET_HEX} + ${OTA_UBOOT_ENV_REDUND_OFFSET_HEX} (redundant)" "info"
    else
        display_alert "OTA U-Boot env prefill" "Wrote ${size} bytes at offset ${OTA_UBOOT_ENV_OFFSET_HEX} (single copy)" "info"
    fi
}
