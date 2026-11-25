# A/B security partition, OP-TEE keybox, and passphrase helpers.
# The keybox mechanism (tee-supplicant lifecycle + keybox_app invocation)
# and the security-partition lookup are single-sourced in common.sh:
# ota_start_tee_supplicant / ota_stop_tee_supplicant / ota_run_keybox_app /
# ota_get_security_part. Flavor policy stays here: no /run stash preference
# (the target-slot unlock wants the device passphrase flow), the by-name
# link preparation, and the raw->keybox migration round-trip.

AB_OTA_BYNAME_DIR="/dev/block/by-name"

# ===== security partition discovery =====
# ota_get_security_part (common.sh) is the single source: disk-anchored
# PARTLABEL=security lookup with unscoped and LABEL fallbacks.

ab_prepare_byname_links() {
    local disk disk_name entry devnode name sec_dev

    mkdir -p "${AB_OTA_BYNAME_DIR}" 2>/dev/null || true

    for disk in /sys/block/*; do
        disk_name="$(basename "${disk}")"
        case "${disk_name}" in
            loop*|ram*|zram*|dm-*|mtdblock*)
                continue
                ;;
        esac

        for entry in "${disk}"/"${disk_name}"*; do
            [ -d "${entry}" ] || continue
            [ -f "${entry}/partition" ] || continue

            devnode="/dev/$(basename "${entry}")"
            name="$(sed -n 's/^PARTNAME=//p' "${entry}/uevent" | head -n1)"
            [ -n "${name}" ] || continue
            ln -sf "${devnode}" "${AB_OTA_BYNAME_DIR}/${name}" 2>/dev/null || true
        done
    done

    sec_dev="$(ota_get_security_part)"
    if [ -n "${sec_dev}" ]; then
        ln -sf "${sec_dev}" "${AB_OTA_BYNAME_DIR}/security" 2>/dev/null || true
    fi
}

# Non-SSKR migration: round-trip the raw key into the keybox so later reads
# come from RPMB instead of the raw partition. Best-effort -- raw value stays
# on failure. Same write/read sequence as the initramfs decryption script.
ab_try_keybox_roundtrip() {
    local out_file="$1"

    cp "${out_file}" "${OTA_SYSPW_FILE}" 2>/dev/null || true
    ota_start_tee_supplicant || {
        log_warn "Failed to start tee-supplicant in non-SSKR path; keep raw key fallback"
        return 0
    }
    /usr/bin/keybox_app write >/dev/null 2>&1 || true
    rm -f "${OTA_SYSPW_FILE}" 2>/dev/null || true
    /usr/bin/keybox_app >/dev/null 2>&1 || true
    ota_stop_tee_supplicant

    if [ -s "${OTA_SYSPW_FILE}" ]; then
        cp "${OTA_SYSPW_FILE}" "${out_file}" 2>/dev/null || true
    fi
    rm -f "${OTA_SYSPW_FILE}" 2>/dev/null || true
    return 0
}

# ===== passphrase retrieval =====
ab_get_security_passphrase_file() {
    local out_file="$1"
    local security_dev marker

    [ -n "${out_file}" ] || return 1
    : > "${out_file}" || return 1
    chmod 600 "${out_file}" 2>/dev/null || true

    # Keep the same preparation steps as initramfs decryption script.
    ab_prepare_byname_links

    security_dev="${AB_OTA_BYNAME_DIR}/security"
    if [ ! -e "${security_dev}" ]; then
        security_dev="$(ota_get_security_part)"
    fi
    [ -n "${security_dev}" ] || {
        log_error "Security partition not found"
        return 1
    }

    marker="$(head -c 4 "${security_dev}" 2>/dev/null || true)"
    log_info "Security partition marker: ${marker:-<empty>}"

    export SECURITY_STORAGE=SECURITY

    rm -f "${OTA_SYSPW_FILE}" 2>/dev/null || true

    if [ "${marker}" = "SSKR" ]; then
        [ -x /usr/bin/keybox_app ] || {
            log_error "SSKR marker detected but /usr/bin/keybox_app is missing"
            return 1
        }
        ota_run_keybox_app || return 1
        [ -s "${OTA_SYSPW_FILE}" ] || {
            log_error "keybox_app did not produce ${OTA_SYSPW_FILE}"
            return 1
        }
        cp "${OTA_SYSPW_FILE}" "${out_file}" || return 1
        rm -f "${OTA_SYSPW_FILE}" 2>/dev/null || true
        return 0
    fi

    # Non-SSKR path: same idea as initramfs (read raw 64 bytes first).
    if ! head -c 64 "${security_dev}" > "${out_file}" 2>/dev/null; then
        log_error "Failed to read raw passphrase from ${security_dev}"
        return 1
    fi

    if [ -x /usr/bin/keybox_app ]; then
        ab_try_keybox_roundtrip "${out_file}"
    fi

    return 0
}
