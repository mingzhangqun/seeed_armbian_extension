# A/B security partition, OP-TEE keybox, and passphrase helpers.

# ===== OP-TEE / keybox mechanism =====
AB_OTA_SYSPW_FILE="/tmp/syspw"
AB_OTA_TEE_LOG="${OTA_WORK_DIR}/armbian-ota-tee-supplicant.log"
AB_OTA_KEYBOX_LOG="${OTA_WORK_DIR}/armbian-ota-keybox.log"
AB_OTA_TEE_PID=""
AB_OTA_BYNAME_DIR="/dev/block/by-name"

# ===== security partition discovery =====
# Anchored to the disk the running root boots from: cloned disks duplicate
# PARTLABEL=security and a first match reads the wrong disk's key partition.
# First-match only as legacy fallback (single-disk, root unresolvable).
ab_get_security_part() {
    local dev disk part root_src

    root_src="$(findmnt -n -o SOURCE /media/root-ro 2>/dev/null || true)"
    [ -n "${root_src}" ] || root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    part="$(ab_resolve_physical_part_dev "${root_src:-}" 2>/dev/null || true)"
    if [ -n "${part}" ]; then
        disk="$(lsblk -no PKNAME "${part}" 2>/dev/null | head -n1 || true)"
    fi
    if [ -n "${disk}" ]; then
        dev="$(blkid -t PARTLABEL=security -o device 2>/dev/null |
            grep -E "^${disk}p[0-9]+$" | head -n1 || true)"
    fi
    [ -z "${dev}" ] && dev="$(blkid -t PARTLABEL=security -o device 2>/dev/null | head -n1)"
    if [ -z "${dev}" ]; then
        dev="$(blkid -t LABEL=security -o device 2>/dev/null | head -n1)"
    fi
    echo "${dev}"
}

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

    sec_dev="$(ab_get_security_part)"
    if [ -n "${sec_dev}" ]; then
        ln -sf "${sec_dev}" "${AB_OTA_BYNAME_DIR}/security" 2>/dev/null || true
    fi
}

# ===== OP-TEE / keybox mechanism =====

ab_start_tee_supplicant() {
    AB_OTA_TEE_PID=""

    [ -x /usr/bin/tee-supplicant ] || return 0

    # A stale tee-supplicant from initramfs may still hold /dev/teepriv0.
    # Restart it in current rootfs namespace so keybox_app can access TA assets.
    mkdir -p "$(dirname "${AB_OTA_TEE_LOG}")" "$(dirname "${AB_OTA_KEYBOX_LOG}")" 2>/dev/null || true
    pkill -9 -x tee-supplicant >/dev/null 2>&1 || true
    sleep 1

    /usr/bin/tee-supplicant >"${AB_OTA_TEE_LOG}" 2>&1 &
    AB_OTA_TEE_PID="$!"
    sleep 1
    if ! kill -0 "${AB_OTA_TEE_PID}" 2>/dev/null; then
        [ -f "${AB_OTA_TEE_LOG}" ] && log_error "tee-supplicant log: $(tail -n 1 "${AB_OTA_TEE_LOG}")"
        return 1
    fi
    return 0
}

ab_stop_tee_supplicant() {
    if [ -n "${AB_OTA_TEE_PID}" ] && kill -0 "${AB_OTA_TEE_PID}" 2>/dev/null; then
        kill "${AB_OTA_TEE_PID}" >/dev/null 2>&1 || true
        wait "${AB_OTA_TEE_PID}" 2>/dev/null || true
    fi
    AB_OTA_TEE_PID=""
}

ab_read_keybox_passphrase() {
    ab_start_tee_supplicant || return 2
    if ! /usr/bin/keybox_app >"${AB_OTA_KEYBOX_LOG}" 2>&1; then
        ab_stop_tee_supplicant
        return 1
    fi
    ab_stop_tee_supplicant
}

ab_try_keybox_roundtrip() {
    local out_file="$1"

    cp "${out_file}" "${AB_OTA_SYSPW_FILE}" 2>/dev/null || true
    ab_start_tee_supplicant || {
        log_warn "Failed to start tee-supplicant in non-SSKR path; keep raw key fallback"
        return 0
    }
    /usr/bin/keybox_app write >"${AB_OTA_KEYBOX_LOG}" 2>&1 || true
    rm -f "${AB_OTA_SYSPW_FILE}" 2>/dev/null || true
    /usr/bin/keybox_app >"${AB_OTA_KEYBOX_LOG}" 2>&1 || true
    ab_stop_tee_supplicant

    if [ -s "${AB_OTA_SYSPW_FILE}" ]; then
        cp "${AB_OTA_SYSPW_FILE}" "${out_file}" 2>/dev/null || true
    fi
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
        security_dev="$(ab_get_security_part)"
    fi
    [ -n "${security_dev}" ] || {
        log_error "Security partition not found"
        return 1
    }

    marker="$(head -c 4 "${security_dev}" 2>/dev/null || true)"
    log_info "Security partition marker: ${marker:-<empty>}"

    export SECURITY_STORAGE=SECURITY

    rm -f "${AB_OTA_SYSPW_FILE}" 2>/dev/null || true

    if [ "${marker}" = "SSKR" ]; then
        [ -x /usr/bin/keybox_app ] || {
            log_error "SSKR marker detected but /usr/bin/keybox_app is missing"
            return 1
        }

        local keybox_status=0
        ab_read_keybox_passphrase || keybox_status=$?
        if [ "${keybox_status}" -eq 2 ]; then
            log_error "Failed to start tee-supplicant in rootfs path"
            return 1
        fi
        if [ "${keybox_status}" -ne 0 ]; then
            log_error "keybox_app read failed in rootfs path"
            [ -f "${AB_OTA_KEYBOX_LOG}" ] && log_error "keybox_app log: $(tail -n 1 "${AB_OTA_KEYBOX_LOG}")"
            return 1
        fi

        if [ ! -s "${AB_OTA_SYSPW_FILE}" ]; then
            log_error "keybox_app did not produce ${AB_OTA_SYSPW_FILE}"
            return 1
        fi
        cp "${AB_OTA_SYSPW_FILE}" "${out_file}" || return 1
        return 0
    fi

    # Non-SSKR path: same idea as initramfs (read raw 64 bytes first).
    if ! head -c 64 "${security_dev}" > "${out_file}" 2>/dev/null; then
        log_error "Failed to read raw passphrase from ${security_dev}"
        return 1
    fi

    # Try keybox write/read round-trip as in initramfs script; fallback to raw on failure.
    if [ -x /usr/bin/keybox_app ]; then
        ab_try_keybox_roundtrip "${out_file}"
    fi

    return 0
}
