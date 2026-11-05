# A/B inactive-slot payload update helpers.

ota_source_library "${OTA_RUNTIME_DIR}/ab/security.sh" "A/B security helper" || return 1

ab_log_extract_progress() {
    local label="$1"
    local percent next=10

    while read -r percent; do
        percent="${percent%.*}"
        case "${percent}" in
            ''|*[!0-9]*) continue ;;
        esac

        while [ "${percent}" -ge "${next}" ] && [ "${next}" -le 100 ]; do
            log_info "${label} extract progress: ${next}%"
            next=$((next + 10))
        done
    done
}

ab_extract_tar_payload() {
    local archive="$1"
    local target="$2"
    local label="$3"
    local size

    # Explicit "<decompressor> | tar -xf -" pipeline, format picked by payload
    # suffix (same lesson as recovery payload.sh): GNU tar only auto-detects
    # compression on seekable archive files, so piping raw tar.xz into
    # "tar -xf -" dies with "Archive is compressed. Use -J option" (observed
    # on rk3576, tar 1.35). xz gets -T0: payloads are compressed with -T0, so
    # decode runs in parallel too (biggest wall-clock lever, per payload.sh).
    local dec
    case "${archive}" in
        *.tar.xz)  dec="xz -dc -T0" ;;
        *.tar.zst) dec="zstd -dc" ;;
        *)         dec="gzip -dc" ;;
    esac

    log_info "Extracting ${label} payload"

    if command -v pv >/dev/null 2>&1; then
        size="$(stat -c '%s' "${archive}" 2>/dev/null || true)"
        if [ -n "${size}" ]; then
            pv -f -n -s "${size}" "${archive}" 2> >(ab_log_extract_progress "${label}" >&2) |
                ${dec} |
                tar --xattrs --acls --numeric-owner -xf - -C "${target}"
        else
            pv -f "${archive}" | ${dec} | tar --xattrs --acls --numeric-owner -xf - -C "${target}"
        fi
        return $?
    fi

    ${dec} "${archive}" | tar --xattrs --acls --numeric-owner -xf - -C "${target}"
}

ab_write_target_state() {
    local root_mnt="$1"
    local package_path="$2"
    local current_slot="$3"
    local target_slot="$4"
    local state_file start_time

    state_file="${root_mnt}/var/lib/armbian-ota/ota-state.env"
    start_time="$(date -Iseconds)"

    (
        OTA_STATE_MODE=ab
        OTA_STATE_STATUS=ready_to_boot
        OTA_STATE_PACKAGE_PATH="$(basename "${package_path}")"
        OTA_STATE_CURRENT_SLOT="${current_slot}"
        OTA_STATE_TARGET_SLOT="${target_slot}"
        OTA_STATE_START_TIME="${start_time}"
        ota_state_write_file "${state_file}"
    ) || error_exit "Failed to write target OTA state"
}

# Rebuild the target root fs via mkfs (fast path over empty_mount_dir).
# Plain targets replay fs label+UUID so slot addressing and boot config stay
# valid; crypto_LUKS targets mkfs the opened mapper only (LUKS header
# untouched). Returns 0 rebuilt, 1 fallback, 2 fatal.
ab_reformat_target_root() {
    local mount_dev="$1"
    local label="$2"
    local root_type="$3"
    local mkfs_opts="-F -q"
    local old_uuid

    if ! command -v mkfs.ext4 >/dev/null 2>&1; then
        log_info "Target root mkfs path skipped: mkfs.ext4 not available, falling back to file cleanup"
        return 1
    fi

    if [ -n "${label}" ]; then
        mkfs_opts="${mkfs_opts} -L ${label}"
    fi

    if [ "${root_type}" != "crypto_LUKS" ]; then
        old_uuid="$(ab_get_uuid_by_dev "${mount_dev}" 2>/dev/null || true)"
        if [ -n "${old_uuid}" ]; then
            mkfs_opts="${mkfs_opts} -U ${old_uuid}"
        fi
    fi

    log_info "Rebuilding target root filesystem via mkfs.ext4 on ${mount_dev}"
    if ! mkfs.ext4 ${mkfs_opts} "${mount_dev}"; then
        log_error "mkfs.ext4 ${mount_dev} failed, target slot unusable"
        return 2
    fi
    return 0
}

ab_apply_target_rootfs() {
    local temp_work="$1"
    local root_mnt="$2"
    local package_path="$3"
    local current_slot="$4"
    local target_slot="$5"
    local rootfs_prebuilt="${6:-0}"

    if [ "${rootfs_prebuilt}" -ne 1 ]; then
        empty_mount_dir "${root_mnt}" || return 1
    fi
    ab_extract_tar_payload "${temp_work}/${OTA_PAYLOAD_ROOTFS_TAR}" "${root_mnt}" "rootfs" || return 1
    ab_write_target_state "${root_mnt}" "${package_path}" "${current_slot}" "${target_slot}"
}

_ab_update_armbian_env_file() {
    local env_file="$1"
    local root_type="$2"
    local root_uuid="$3"

    [ -f "${env_file}" ] || return 0

    if [ "${root_type}" = "crypto_LUKS" ]; then
        if grep -q '^rootdev=' "${env_file}"; then
            sed -i 's|^rootdev=.*$|rootdev=/dev/mapper/armbian-root|' "${env_file}" || return 1
        else
            printf '\nrootdev=/dev/mapper/armbian-root\n' >> "${env_file}" || return 1
        fi

        [ -n "${root_uuid}" ] || return 0
        if grep -q '^cryptdevice=' "${env_file}"; then
            sed -i "s|^cryptdevice=.*$|cryptdevice=UUID=${root_uuid}:armbian-root|" "${env_file}" || return 1
        else
            printf 'cryptdevice=UUID=%s:armbian-root\n' "${root_uuid}" >> "${env_file}" || return 1
        fi
        return 0
    fi

    [ -n "${root_uuid}" ] || return 0
    if grep -q '^rootdev=' "${env_file}"; then
        sed -i "s|^rootdev=UUID=.*$|rootdev=UUID=${root_uuid}|" "${env_file}" || return 1
        sed -i "s|^rootdev=PARTUUID=.*$|rootdev=UUID=${root_uuid}|" "${env_file}" || return 1
    else
        printf '\nrootdev=UUID=%s\n' "${root_uuid}" >> "${env_file}" || return 1
    fi
}

ab_update_armbian_env() {
    local arm_env="$1"
    local root_type="$2"
    local root_uuid="$3"

    [ -f "${arm_env}" ] || return 0

    _ab_update_armbian_env_file "${arm_env}" "${root_type}" "${root_uuid}" || return 1

    # Keep armbianEnv.txt.dist in sync so the boot.scr fallback still
    # points at the current rootfs after OTA. Otherwise a later txt
    # corruption would fall back to a stale UUID and fail to rescue.
    # Runs before the overlays merge so the .dist baseline never absorbs
    # user overlays.
    local dist_env="${arm_env}.dist"
    if [ -f "${dist_env}" ]; then
        _ab_update_armbian_env_file "${dist_env}" "${root_type}" "${root_uuid}" || return 1
    else
        cp -a "${arm_env}" "${dist_env}"
    fi
}

# Effective (last-wins) value of a key in an env file, empty if absent.
_ab_env_get_key() {
    local env_file="$1" key="$2"

    [ -f "${env_file}" ] || return 0
    sed -n "s/^${key}=//p" "${env_file}" | tail -n 1
}

_ab_set_env_key() {
    local env_file="$1" key="$2" value="$3"

    if grep -q "^${key}=" "${env_file}"; then
        sed -i "s|^${key}=.*$|${key}=${value}|" "${env_file}" || return 1
    else
        printf '\n%s=%s\n' "${key}" "${value}" >> "${env_file}" || return 1
    fi
}

# Overlays value from the running slot's env — the only place user edits
# live, since the target slot only ever received OTA baselines. Falls back
# to mounting the running slot's boot partition read-only when /boot is not
# available. Empty output means nothing to migrate. Raw-FIT layouts have no
# env filesystem at all; every failure path degrades to "skip migration".
_ab_capture_current_overlays() {
    local env_file="/boot/armbianEnv.txt" slot dev mnt

    if [ -f "${env_file}" ]; then
        _ab_env_get_key "${env_file}" overlays
        return 0
    fi

    slot="$(ab_get_current_slot 2>/dev/null || true)"
    case "${slot}" in
        a|b) ;;
        *)
            log_warn "Cannot determine running slot; skipping overlays migration"
            return 0
            ;;
    esac

    dev="$(ab_get_part_by_label "$(ab_get_slot_boot_label "${slot}")" 2>/dev/null || true)"
    if [ -z "${dev}" ] || [ ! -b "${dev}" ]; then
        log_warn "Running slot boot partition not found; skipping overlays migration"
        return 0
    fi

    mnt="$(make_ota_work_dir "ab-current-boot-ro")"
    if ! mount -t ext4 -o ro "${dev}" "${mnt}"; then
        log_warn "Failed to mount ${dev} read-only; skipping overlays migration"
        if ! mountpoint -q "${mnt}" 2>/dev/null; then rm -rf "${mnt}"; fi
        return 0
    fi
    _ab_env_get_key "${mnt}/armbianEnv.txt" overlays
    umount "${mnt}" 2>/dev/null || log_warn "Failed to unmount ${mnt}"
    rm -rf "${mnt}"
}

# Preserve user DT overlays across slot updates: merge the running slot's
# overlays value into the freshly written target env. Baseline entries keep
# their build-verified order (the RK3588 GPU stack overlay must stay
# first-class); entries only present in the old value are appended,
# deduplicated.
ab_merge_env_overlays() {
    local env_file="$1"
    local old_overlays merged

    [ -f "${env_file}" ] || return 0

    old_overlays="$(_ab_capture_current_overlays)"
    [ -n "${old_overlays}" ] || {
        log_info "Running slot has no overlays= value; keeping target baseline"
        return 0
    }

    merged="$(printf '%s\n%s\n' "$(_ab_env_get_key "${env_file}" overlays)" "${old_overlays}" |
        tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' |
        sed 's/[[:space:]]*$//')"
    [ -n "${merged}" ] || return 0

    log_info "Merged overlays into target env: ${merged}"
    _ab_set_env_key "${env_file}" overlays "${merged}"
}

ab_write_target_boot_itb() {
    local image="$1" target="$2" target_slot="$3"
    local expected_partlabel image_size target_size partlabel

    case "${target_slot}" in
        a|b) ;;
        *) error_exit "Invalid target slot for FIT boot image: ${target_slot}" ;;
    esac

    [ -f "${image}" ] || error_exit "Missing FIT boot payload: ${image}"
    [ -b "${target}" ] || error_exit "FIT boot target is not a block device: ${target}"

    expected_partlabel="$(ab_get_slot_boot_partlabel "${target_slot}")" ||
        error_exit "Invalid target slot for FIT boot image: ${target_slot}"
    partlabel="$(ab_get_partlabel_by_dev "${target}" || true)"
    [ "${partlabel}" = "${expected_partlabel}" ] ||
        error_exit "Refusing to write FIT boot image to ${target}: expected PARTLABEL=${expected_partlabel}, found ${partlabel:-<empty>}"

    ota_is_fit_image "${image}" || error_exit "Refusing to write invalid FIT boot image: ${image}"

    image_size="$(stat -c '%s' "${image}" 2>/dev/null || true)"
    target_size="$(blockdev --getsize64 "${target}" 2>/dev/null || true)"
    [ -n "${image_size}" ] && [ -n "${target_size}" ] && [ "${image_size}" -le "${target_size}" ] ||
        error_exit "FIT boot image size check failed: image=${image_size:-unknown}, target=${target_size:-unknown}"

    log_info "Writing FIT boot image ${image} (${image_size} bytes) to target slot ${target_slot}: ${target}"
    dd if="${image}" of="${target}" bs=4M conv=fsync ||
        error_exit "Failed to write FIT boot image to ${target}"
    sync
}

ab_update_target_bootfs() {
    local temp_work="$1"
    local target_boot_dev="$2"
    local target_root_type="$3"
    local target_root_uuid="$4"
    local boot_mnt arm_env

    boot_mnt="$(make_ota_work_dir "ab-boot-mnt")"
    if ! mount -t ext4 -o rw "${target_boot_dev}" "${boot_mnt}"; then
        log_error "Failed to mount target boot partition"
        rm -rf "${boot_mnt}"
        return 1
    fi

    if [ -f "${temp_work}/${OTA_PAYLOAD_BOOT_TAR}" ]; then
        empty_mount_dir "${boot_mnt}" || {
            log_error "Failed to clear target boot partition"
            umount "${boot_mnt}" 2>/dev/null || log_warn "Failed to unmount target boot partition after clear failure"
            if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then rm -rf "${boot_mnt}"; fi
            return 1
        }
        ab_extract_tar_payload "${temp_work}/${OTA_PAYLOAD_BOOT_TAR}" "${boot_mnt}" "boot" || {
            log_error "Failed to extract boot payload"
            umount "${boot_mnt}" 2>/dev/null || log_warn "Failed to unmount target boot partition after extraction failure"
            if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then rm -rf "${boot_mnt}"; fi
            return 1
        }
        sync
    fi

    arm_env="${boot_mnt}/armbianEnv.txt"
    if ! ab_update_armbian_env "${arm_env}" "${target_root_type}" "${target_root_uuid}"; then
        log_error "Failed to update target boot environment"
        umount "${boot_mnt}" 2>/dev/null || log_warn "Failed to unmount target boot partition after environment update failure"
        if ! mountpoint -q "${boot_mnt}" 2>/dev/null; then rm -rf "${boot_mnt}"; fi
        return 1
    fi
    ab_merge_env_overlays "${arm_env}" ||
        log_warn "Failed to merge overlays into target boot env"
    if ! umount "${boot_mnt}"; then
        log_error "Failed to unmount target boot partition"
        return 1
    fi
    rm -rf "${boot_mnt}"
}

ab_update_target_root_boot_env() {
    local root_mnt="$1"
    local target_root_type="$2"
    local target_root_uuid="$3"
    local arm_env="${root_mnt}/boot/armbianEnv.txt"

    [ -f "${arm_env}" ] || return 0
    ab_update_armbian_env "${arm_env}" "${target_root_type}" "${target_root_uuid}" || {
        log_error "Failed to update target root boot environment"
        return 1
    }
    # Raw-FIT (encrypted) targets have no env filesystem to migrate from;
    # the capture helper soft-skips there. For boot.scr layouts without
    # separate boot partitions this env is the live one and gets the
    # running slot's overlays merged in.
    ab_merge_env_overlays "${arm_env}" ||
        log_warn "Failed to merge overlays into target root env"
}

ab_update_target_boot() {
    local temp_work="$1"
    local root_mnt="$2"
    local target_boot_dev="$3"
    local target_slot="$4"
    local target_root_type="$5"
    local target_root_uuid="$6"

    if [ -f "${temp_work}/${OTA_PAYLOAD_BOOT_ITB}" ]; then
        [ -n "${target_boot_dev}" ] || error_exit "Cannot find target boot partition for FIT boot image"
        ab_write_target_boot_itb "${temp_work}/${OTA_PAYLOAD_BOOT_ITB}" "${target_boot_dev}" "${target_slot}"
        ab_update_target_root_boot_env "${root_mnt}" "${target_root_type}" "${target_root_uuid}"
    elif [ -n "${target_boot_dev}" ] && [ -b "${target_boot_dev}" ]; then
        ab_update_target_bootfs "${temp_work}" "${target_boot_dev}" "${target_root_type}" "${target_root_uuid}"
    else
        ab_update_target_root_boot_env "${root_mnt}" "${target_root_type}" "${target_root_uuid}"
    fi
}

ab_update_target_filesystem_config() {
    local root_mnt="$1"
    local target_root_label="$2"
    local target_boot_label="$3"
    local target_root_type="$4"
    local target_root_uuid="$5"
    local target_boot_uuid="$6"
    local fstab="${root_mnt}/etc/fstab"
    local crypttab="${root_mnt}/etc/crypttab"
    local existing_root_uuid existing_boot_uuid

    if [ -f "${fstab}" ]; then
        cp "${fstab}" "${fstab}.ota-backup" || return 1
        existing_root_uuid="$(grep -m1 'UUID=[0-9a-f-]*[[:space:]][[:space:]]*/[[:space:]]' "${fstab}" | sed -n 's/.*UUID=\([0-9a-f-]*\).*/\1/p')"
        existing_boot_uuid="$(grep -m1 'UUID=[0-9a-f-]*[[:space:]][[:space:]]*/boot[[:space:]]' "${fstab}" | sed -n 's/.*UUID=\([0-9a-f-]*\).*/\1/p')"

        if [ "${target_root_type}" = "crypto_LUKS" ]; then
            sed -i -E 's|^UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${fstab}" || return 1
            sed -i -E 's|^/dev/[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${fstab}" || return 1
        elif [ -n "${existing_root_uuid}" ] && [ -n "${target_root_uuid}" ]; then
            sed -i "s|UUID=${existing_root_uuid}|UUID=${target_root_uuid}|g" "${fstab}" || return 1
        fi
        if [ -n "${existing_boot_uuid}" ] && [ -n "${target_boot_uuid}" ]; then
            sed -i "s|UUID=${existing_boot_uuid}|UUID=${target_boot_uuid}|g" "${fstab}" || return 1
        fi

        sed -i "s|LABEL=${ROOT_A_LABEL}|LABEL=${target_root_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=${ROOT_B_LABEL}|LABEL=${target_root_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=${BOOT_A_LABEL}|LABEL=${target_boot_label}|g" "${fstab}" || return 1
        sed -i "s|LABEL=${BOOT_B_LABEL}|LABEL=${target_boot_label}|g" "${fstab}" || return 1
    fi

    if [ "${target_root_type}" = "crypto_LUKS" ] && [ -f "${crypttab}" ] && [ -n "${target_root_uuid}" ]; then
        sed -i -E "s|^(armbian-root[[:space:]]+)UUID=[0-9a-fA-F-]+|\\1UUID=${target_root_uuid}|" "${crypttab}" || return 1
    fi
}

ab_cleanup_target_root() {
    local root_mnt="$1"
    local luks_mapper="$2"
    local luks_opened="$3"
    local cleanup_failed=0

    if mountpoint -q "${root_mnt}" 2>/dev/null && ! umount "${root_mnt}"; then
        log_warn "Failed to unmount target root partition"
        cleanup_failed=1
    fi
    if [ "${luks_opened}" -eq 1 ] && [ -n "${luks_mapper}" ] && ! cryptsetup luksClose "${luks_mapper}" >/dev/null 2>&1; then
        log_warn "Failed to close mapper ${luks_mapper}"
        cleanup_failed=1
    fi
    if ! mountpoint -q "${root_mnt}" 2>/dev/null; then
        rm -rf "${root_mnt}" || cleanup_failed=1
    fi

    return "${cleanup_failed}"
}

ab_update_target_partition() {
    local temp_work="$1"
    local target_root_label="$2"
    local target_boot_label="$3"
    local package_path="$4"
    local current_slot="$5"
    local target_slot target_root_dev target_boot_dev root_mnt
    local target_root_uuid target_boot_uuid
    local target_root_type target_root_mount_dev target_root_luks_uuid
    local security_dev key_file luks_mapper luks_opened
    local rootfs_prebuilt fmt_rc

    target_slot="$(ab_get_slot_by_label "${target_root_label}")" ||
        error_exit "Invalid target root partition label: ${target_root_label}"
    target_root_dev="$(ab_get_part_by_label "${target_root_label}")"
    target_boot_dev="$(ab_get_part_by_label "${target_boot_label}")"
    [ -n "${target_root_dev}" ] || error_exit "Cannot find target root partition: ${target_root_label}"

    target_root_type="$(ab_get_fstype_by_dev "${target_root_dev}" || true)"
    target_root_mount_dev="${target_root_dev}"
    target_root_luks_uuid=""
    security_dev=""
    key_file=""
    luks_mapper=""
    luks_opened=0

    if [ "${target_root_type}" = "crypto_LUKS" ]; then
        command -v cryptsetup >/dev/null 2>&1 || error_exit "cryptsetup is required for encrypted AB OTA target partition"
        security_dev="$(ab_get_security_part)"
        [ -n "${security_dev}" ] || error_exit "Security partition not found for encrypted AB OTA"

        key_file="$(make_ota_temp_file "ab-key")"
        if ! ab_get_security_passphrase_file "${key_file}"; then
            rm -f "${key_file}" 2>/dev/null || true
            error_exit "Failed to obtain decryption passphrase from security flow (${security_dev})"
        fi

        luks_mapper="armbian-ota-root-${target_slot}"
        if [ -e "/dev/mapper/${luks_mapper}" ]; then
            cryptsetup luksClose "${luks_mapper}" >/dev/null 2>&1 || true
        fi
        cat "${key_file}" | cryptsetup luksOpen "${target_root_dev}" "${luks_mapper}" ||
            cryptsetup luksOpen "${target_root_dev}" "${luks_mapper}" --key-file "${key_file}" ||
            { rm -f "${key_file}" 2>/dev/null || true; error_exit "Failed to unlock encrypted target root ${target_root_dev}"; }
        rm -f "${key_file}" 2>/dev/null || true
        key_file=""

        target_root_mount_dev="/dev/mapper/${luks_mapper}"
        target_root_luks_uuid="$(ab_get_uuid_by_dev "${target_root_dev}" || true)"
        luks_opened=1
        log_info "Encrypted target slot ${target_slot}: root=${target_root_dev} mapper=${target_root_mount_dev}"
    else
        log_info "Updating slot ${target_slot}: root=${target_root_dev} boot=${target_boot_dev:-<none>}"
    fi

    root_mnt="$(make_ota_work_dir "ab-root-mnt")"
    rootfs_prebuilt=0
    ab_reformat_target_root "${target_root_mount_dev}" "${target_root_label}" "${target_root_type}"
    fmt_rc=$?
    if [ "${fmt_rc}" -eq 2 ]; then
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to rebuild target root filesystem"
    fi
    [ "${fmt_rc}" -eq 0 ] && rootfs_prebuilt=1

    mount -t ext4 -o rw "${target_root_mount_dev}" "${root_mnt}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to mount target root partition"
    }

    # OTA hook points (docs/10-ota-package-formats.md): the staged hook is
    # sourced once (definition-only), then hook_pre_apply / hook_apply /
    # hook_post_apply run at fixed points around the built-in flow. A defined
    # hook_apply replaces payload application (rootfs + boot); slot/env
    # bookkeeping, filesystem config, sync and cleanup stay here. Hooks that
    # define hook_firstboot get the script carried into the target slot for
    # the firstboot oneshot service.
    ota_source_hook "${temp_work}" || true
    OTA_HOOK_MODE="ab"
    OTA_DIR="${temp_work}"
    ROOTFS_TAR="${temp_work}/${OTA_PAYLOAD_ROOTFS_TAR}"
    BOOT_TAR="${temp_work}/${OTA_PAYLOAD_BOOT_TAR}"
    BOOT_ITB="${temp_work}/${OTA_PAYLOAD_BOOT_ITB}"
    export OTA_HOOK_API OTA_HOOK_MODE OTA_HOOK_PATH OTA_DIR ROOTFS_TAR BOOT_TAR BOOT_ITB

    if ! ota_call_hook hook_pre_apply; then
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "OTA hook hook_pre_apply failed"
    fi

    if type hook_apply >/dev/null 2>&1; then
        log_info "OTA hook hook_apply takes over payload application"
        hook_apply || {
            ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
            error_exit "OTA hook hook_apply failed"
        }
    else
        ab_apply_target_rootfs "${temp_work}" "${root_mnt}" "${package_path}" "${current_slot}" "${target_slot}" "${rootfs_prebuilt}" || {
            ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
            error_exit "Failed to apply rootfs payload"
        }
    fi

    if [ "${target_root_type}" = "crypto_LUKS" ]; then
        target_root_uuid="${target_root_luks_uuid}"
    else
        target_root_uuid="$(ab_get_uuid_by_label "${target_root_label}")"
    fi
    target_boot_uuid="$(ab_get_uuid_by_label "${target_boot_label}")"
    if type hook_apply >/dev/null 2>&1; then
        log_info "OTA hook hook_apply owns target boot update as well"
    else
        ab_update_target_boot "${temp_work}" "${root_mnt}" "${target_boot_dev}" "${target_slot}" "${target_root_type}" "${target_root_uuid}" || {
            ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
            error_exit "Failed to update target boot partition"
        }
    fi
    ab_update_target_filesystem_config "${root_mnt}" "${target_root_label}" "${target_boot_label}" "${target_root_type}" "${target_root_uuid}" "${target_boot_uuid}" || {
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "Failed to update target filesystem configuration"
    }

    # Carry the hook into the target slot when it wants a firstboot run.
    if type hook_firstboot >/dev/null 2>&1 && [ -n "${OTA_HOOK_PATH:-}" ]; then
        mkdir -p "${root_mnt}/usr/share/armbian-ota"
        cp "${OTA_HOOK_PATH}" "${root_mnt}/usr/share/armbian-ota/firstboot-hook.sh" || {
            ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
            error_exit "Failed to stage firstboot hook into target slot"
        }
    fi

    if ! ota_call_hook hook_post_apply; then
        ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" || true
        error_exit "OTA hook hook_post_apply failed"
    fi

    sync
    ab_cleanup_target_root "${root_mnt}" "${luks_mapper}" "${luks_opened}" ||
        error_exit "Failed to clean up target root partition"
}
