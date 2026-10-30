#!/bin/sh
#
# Recovery initramfs source: payload apply, FIT write, config patch, state commit.
#
# Sourced by 99-ota-apply AFTER recovery/log.sh and recovery/device.sh (uses log/heartbeat
# and device primitives) and state.sh (uses ota_state_write_file).
# /bin/sh + busybox userland.
#
# Expects globals from the orchestrator: ROOT_MNT, BOOT_MNT, STATE_DIR,
# STATE_FILE, OTA_DIR, ROOTFS_TAR, BOOT_TAR, BOOT_ITB.
# Reads globals from ota_detect_devices: ROOT_DEV, ROOT_UUID, BOOT_DEV,
# BOOT_UUID, HAS_BOOT_PART, AUTO_DECRYPT_MODE.
# Sets globals: HAS_BOOT_TAR, HAS_BOOT_ITB, DO_BOOT_OTA, BOOT_MNT (reassigned).

# ===== tar extract helper with stderr logging =====
# Format map (initramfs mirror; keep in sync with common.sh and
# package-create.sh -- docs/10-ota-package-formats.md).
#
# Extraction always runs as an explicit "<decompressor> -dc | tar -xf -"
# pipeline with tools resolved by absolute path (/usr/bin first). Two reasons,
# both learned on real boards:
#   1. "tar -xJf --numeric-owner FILE" is broken for ANY tar flavor: the -f
#      option consumes the next token as the archive name, so the flag string
#      is eaten as a filename ("can't open '--numeric-owner'"). Options must
#      not sit between -f and its value.
#   2. Relying on PATH can pick the busybox applet over the real binary the
#      99-copy-tools hook staged (observed: initrd carries real GNU tar under
#      /usr/bin while the phase-2 shell still ran busybox tar). Absolute-path
#      resolution plus the pipe also guarantees the real, threaded xz/gzip
#      does the decoding instead of whatever tar's internal spawn finds.
ota_resolve_tool() {
    tool="$1"

    for candidate in "/usr/bin/${tool}" "/bin/${tool}" "${tool}"; do
        if [ -x "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

# True when $TAR_BIN is real GNU tar (gets the attribute-preserving flags;
# busybox tar only understands --numeric-owner).
ota_tar_gnu() {
    if [ -z "${OTA_TAR_IS_GNU:-}" ]; then
        if "${TAR_BIN}" --version 2>/dev/null | head -n1 | grep -q "GNU tar"; then
            OTA_TAR_IS_GNU=1
        else
            OTA_TAR_IS_GNU=0
        fi
    fi
    [ "${OTA_TAR_IS_GNU}" = "1" ]
}

extract_tar() {
    archive="$1"
    target="$2"
    label="$3"
    err_file="${LOGDIR}/${label}.tar.stderr.log"
    dec_status="${LOGDIR}/${label}.dec.status"

    rm -f "${err_file}" "${dec_status}" 2>/dev/null || true

    TAR_BIN="$(ota_resolve_tool tar)"
    DEC_FLAGS=""
    case "${archive}" in
        *.tar.xz)
            DEC_BIN="$(ota_resolve_tool xz)"
            # Payload xz archives are compressed with -T0 (multi-block), so
            # decode can run in parallel too; on-device timing showed this
            # is the single biggest OTA wall-clock lever for xz packages.
            # Harmless on single-block archives.
            DEC_FLAGS="-T0"
            ;;
        *.tar.zst) DEC_BIN="$(ota_resolve_tool zstd)" ;;
        *)         DEC_BIN="$(ota_resolve_tool gzip)" ;;
    esac
    if [ -z "${TAR_BIN}" ] || [ -z "${DEC_BIN}" ]; then
        log "ERROR: ${label}: no usable tar/decompressor (tar=${TAR_BIN:-none} dec=${DEC_BIN:-none})"
        return 1
    fi

    tar_flags="--numeric-owner"
    if ota_tar_gnu; then
        tar_flags="${tar_flags} --xattrs --acls"
    fi

    log "${label}: ${DEC_BIN} ${DEC_FLAGS} -dc ${archive} | ${TAR_BIN} ${tar_flags} -xf - -C ${target}"
    # busybox ash has no pipefail; the decompressor exit status travels through
    # a side file because tar alone can exit 0 on a corrupt stream once it has
    # seen the archive end marker before the decompressor bailed.
    rc=0
    dec_rc=1
    {
        (
            "${DEC_BIN}" ${DEC_FLAGS} -dc "${archive}"
            echo $? >"${dec_status}"
        ) | "${TAR_BIN}" ${tar_flags} -xf - -C "${target}"
    } 2>"${err_file}" || rc=$?
    dec_val="$(cat "${dec_status}" 2>/dev/null)"
    [ -n "${dec_val}" ] && dec_rc="${dec_val}"
    if [ "${rc}" -eq 0 ] && [ "${dec_rc}" -eq 0 ]; then
        log "${label}: extract succeeded"
        log_tail "${label}" "${err_file}" 20
        rm -f "${err_file}" "${dec_status}" 2>/dev/null || true
        return 0
    fi

    log "ERROR: ${label} extract failed (tar rc=${rc}, decompressor rc=${dec_rc})"
    log_tail "${label} stderr" "${err_file}" 80
    rm -f "${err_file}" "${dec_status}" 2>/dev/null || true
    return 1
}

# ===== package-provided OTA hook (OTA_HOOK_API=1) =====
# Fixed call points around the built-in phase-2 flow (docs/10-ota-package-formats.md):
# hook_pre_apply / hook_apply / hook_post_apply are invoked by 99-ota-apply.
# Hook scripts are sourced in every phase and must be definition-only.
OTA_HOOK_API="1"

# Resolve the staged hook filename: declared OTA_HOOK (legacy OTA_APPLY_HOOK
# accepted) wins, then conventional ota-hook.sh, then the legacy name.
ota_hook_name_staged() {
    hook_name=""

    if [ -f "${OTA_DIR}/package.env" ]; then
        hook_name="$(sed -n 's/^OTA_HOOK=//p' "${OTA_DIR}/package.env" | head -n1)"
        [ -z "${hook_name}" ] && hook_name="$(sed -n 's/^OTA_APPLY_HOOK=//p' "${OTA_DIR}/package.env" | head -n1)"
    fi
    [ -n "${hook_name}" ] && [ -f "${OTA_DIR}/${hook_name}" ] || hook_name="ota-hook.sh"
    [ -f "${OTA_DIR}/${hook_name}" ] || hook_name="ota-apply-hook.sh"
    [ -f "${OTA_DIR}/${hook_name}" ] || return 1
    printf '%s\n' "${hook_name}"
}

# Source the staged hook once; sets OTA_HOOK_PATH. rc 1 = package has no hook.
ota_source_staged_hook() {
    OTA_HOOK_PATH=""

    hook_name="$(ota_hook_name_staged)" || return 1
    OTA_HOOK_PATH="${OTA_DIR}/${hook_name}"
    log "OTA hook loaded: ${hook_name} (API ${OTA_HOOK_API})"
    # shellcheck disable=SC1090
    . "${OTA_HOOK_PATH}" || {
        log "ERROR: failed to source ${OTA_HOOK_PATH}"
        return 1
    }
    return 0
}

# Call $1 if the hook defined it; no-op otherwise, rc passthrough.
ota_call_hook() {
    fn="$1"

    type "${fn}" >/dev/null 2>&1 || return 0
    log "OTA hook point: ${fn}"
    "${fn}"
}

# Capture the pre-OTA armbianEnv before a hook can reformat anything, so
# ota_patch_config's overlays merge keeps working when the built-in apply
# (which owns this capture) is replaced by hook_apply.
ota_capture_pre_ota_env() {
    if [ -f "${ROOT_MNT}/boot/armbianEnv.txt" ]; then
        cp "${ROOT_MNT}/boot/armbianEnv.txt" "${LOGDIR}/armbianEnv.pre-ota" &&
            log "captured pre-OTA armbianEnv.txt from rootfs /boot"
    fi
    if [ "${HAS_BOOT_PART:-0}" -eq 1 ]; then
        mkdir -p /mnt/preenv
        if mount -t ext4 -o ro "${BOOT_DEV}" /mnt/preenv 2>/dev/null; then
            if [ -f /mnt/preenv/armbianEnv.txt ]; then
                cp /mnt/preenv/armbianEnv.txt "${LOGDIR}/armbianEnv.pre-ota" &&
                    log "captured pre-OTA armbianEnv.txt from boot partition"
            fi
            umount /mnt/preenv 2>/dev/null || true
        fi
        rmdir /mnt/preenv 2>/dev/null || true
    fi
    return 0
}

set_env_key() {
    file="$1"
    key="$2"
    value="$3"

    if grep -q "^${key}=" "${file}"; then
        sed -i "s|^${key}=.*$|${key}=${value}|" "${file}"
    else
        printf '\n%s=%s\n' "${key}" "${value}" >> "${file}"
    fi
}

write_raw_boot_itb() {
    image="$1"
    target="$2"

    [ -f "${image}" ] || return 0
    [ -b "${target}" ] || {
        log "ERROR: boot.itb target is not a block device: ${target}"
        return 1
    }

    partname="$(get_partname_for_dev "${target}" || true)"
    [ "${partname}" = "boot" ] || {
        log "ERROR: refusing to write boot.itb to ${target}: PARTNAME=${partname:-<empty>}"
        return 1
    }

    if ! is_fit_image "${image}"; then
        log "ERROR: refusing to write invalid FIT image: ${image}"
        return 1
    fi

    image_size="$(file_size_bytes "${image}")"
    target_size="$(blockdev_size_bytes "${target}")"
    if [ -z "${image_size}" ] || [ -z "${target_size}" ] || [ "${image_size}" -gt "${target_size}" ]; then
        log "ERROR: boot.itb size check failed: image=${image_size:-unknown}, target=${target_size:-unknown}"
        return 1
    fi

    log "writing raw FIT boot image ${image} (${image_size} bytes) -> ${target} (${target_size} bytes)"
    start_heartbeat "writing boot.itb to ${target}"
    if ! dd if="${image}" of="${target}" bs=4M conv=fsync 2>>"${LOGFILE}"; then
        stop_heartbeat
        log "ERROR: failed to write boot.itb to ${target}"
        log_tail "boot.itb dd stderr" "${LOGFILE}" 20
        return 1
    fi
    stop_heartbeat
    sync
}

# ===== validate recovery state on mounted rootfs =====
# Returns 1 (caller unmounts+skips) when state/payload is not applicable.
ota_validate_recovery_state() {
    if [ ! -f "${STATE_FILE}" ]; then
        log "no OTA state file at ${STATE_FILE}, unmount and skip"
        return 1
    fi

    if ! grep -q '^OTA_MODE=recovery$' "${STATE_FILE}" 2>/dev/null ||
       ! grep -q '^STATUS=prepared$' "${STATE_FILE}" 2>/dev/null; then
        log "OTA state is not recovery/prepared, unmount and skip"
        return 1
    fi

    # check OTA payload: rootfs.tar.gz is required, boot.tar.gz is optional
    if [ ! -d "${OTA_DIR}" ] || [ ! -f "${ROOTFS_TAR}" ]; then
        log "no rootfs OTA payload at ${OTA_DIR}, unmount and skip"
        return 1
    fi

    # Payload/system encryption match (phase-2 backstop; phase 1 already
    # rejects the mismatched pairs before anything is touched). The .enc blob
    # stays staged after the phase-1 decrypt, so its presence still marks an
    # encrypted package here.
    if [ -f "${OTA_DIR}/rootfs.tar.xz.enc" ] || [ -f "${OTA_DIR}/rootfs.tar.gz.enc" ]; then
        pkg_encrypted=1
    else
        pkg_encrypted=0
    fi
    if [ "${pkg_encrypted}" != "${AUTO_DECRYPT_MODE:-0}" ]; then
        log "ERROR: payload/system encryption mismatch (encrypted payload=${pkg_encrypted}, auto-decrypt mode=${AUTO_DECRYPT_MODE:-0}), abort"
        return 1
    fi

    # If a payload manifest shipped (encrypted payload was decrypted in phase 1),
    # re-check the plaintext rootfs tar sha256 against it before applying, so a
    # tamper of the transaction store between phase 1 and phase 2 is caught.
    if [ -f "${OTA_DIR}/payload.manifest" ]; then
        if ! command -v sha256sum >/dev/null 2>&1; then
            log "ERROR: sha256sum unavailable in initramfs; cannot re-check plaintext rootfs sha; abort"
            return 1
        fi
        expected_root_sha="$(sed -n 's/^OTA_PAYLOAD_ROOTFS_SHA256=//p' "${OTA_DIR}/payload.manifest" | head -n1)"
        if [ -n "${expected_root_sha}" ]; then
            actual_root_sha="$(sha256sum "${ROOTFS_TAR}" | awk '{print $1}')"
            if [ "${actual_root_sha}" != "${expected_root_sha}" ]; then
                log "ERROR: plaintext rootfs sha256 (${actual_root_sha}) != manifest (${expected_root_sha}); possible tamper, abort"
                return 1
            fi
            log "recovery: plaintext rootfs sha256 matches payload manifest"
        fi
    fi

    HAS_BOOT_TAR=0
    [ -f "${BOOT_TAR}" ] && HAS_BOOT_TAR=1
    HAS_BOOT_ITB=0
    [ -f "${BOOT_ITB}" ] && HAS_BOOT_ITB=1

    # Package-requested deferral of the built-in boot refresh
    # (OTA_BOOT_REFRESH=0 in package.env): ota_apply_boot is skipped so the
    # package hook owns a per-file atomic swap instead
    # (recovery/hooks/boot-atomic-swap.sh). Absent key keeps legacy behavior.
    OTA_BOOT_HOOK_MODE=0
    if [ "${HAS_BOOT_TAR}" -eq 1 ]; then
        bsw_flag="$(sed -n 's/^OTA_BOOT_REFRESH=//p' "${OTA_DIR}/package.env" 2>/dev/null | head -n1)"
        if [ "${bsw_flag}" = "0" ]; then
            OTA_BOOT_HOOK_MODE=1
            HAS_BOOT_TAR=0
            log "boot refresh deferred to OTA hook (package.env OTA_BOOT_REFRESH=0)"
        fi
    fi

    log "found rootfs OTA payload, HAS_BOOT_PART=${HAS_BOOT_PART}, HAS_BOOT_TAR=${HAS_BOOT_TAR}, HAS_BOOT_ITB=${HAS_BOOT_ITB}, hook_mode=${OTA_BOOT_HOOK_MODE}"
    return 0
}

# ===== rebuild rootfs via mkfs (fast path over rm -rf clean) =====
# Needs a separate boot partition. Returns 0 rebuilt, 1 fallback, 2 fatal.
ota_reformat_rootfs() {
    if [ "${HAS_BOOT_PART:-0}" -ne 1 ]; then
        log "mkfs path skipped: no separate boot partition, /boot stays on rootfs"
        return 1
    fi

    if ! command -v mkfs.ext4 >/dev/null 2>&1; then
        log "mkfs path skipped: mkfs.ext4 not available in initramfs"
        return 1
    fi

    if [ -z "${ROOT_DEV}" ] || [ ! -b "${ROOT_DEV}" ]; then
        log "mkfs path skipped: ROOT_DEV is not a block device: ${ROOT_DEV:-<empty>}"
        return 1
    fi

    if ! umount "${ROOT_MNT}"; then
        log "mkfs path skipped: failed to umount ${ROOT_MNT}, falling back to clean"
        return 1
    fi

    # Point of no return: the old fs is now only on-disk data.
    mkfs_opts="-F -q -L armbi_root"
    # Replay the fs UUID so rootdev= keeps resolving (auto-decrypt skips it:
    # ROOT_UUID is the LUKS container UUID, not the fs one).
    if [ "${AUTO_DECRYPT_MODE:-0}" -eq 0 ] && [ -n "${ROOT_UUID}" ]; then
        mkfs_opts="${mkfs_opts} -U ${ROOT_UUID}"
    fi

    start_heartbeat "mkfs rootfs at ${ROOT_DEV}"
    if ! mkfs.ext4 ${mkfs_opts} "${ROOT_DEV}" 2>>"${LOGFILE}"; then
        stop_heartbeat
        log "ERROR: mkfs.ext4 ${ROOT_DEV} failed, rootfs unrecoverable, abort OTA"
        return 2
    fi
    stop_heartbeat

    if ! mount -t ext4 "${ROOT_DEV}" "${ROOT_MNT}"; then
        log "ERROR: cannot remount ${ROOT_DEV} after mkfs, abort OTA"
        return 2
    fi

    # Refresh the fs UUID from disk (-p bypasses the blkid cache).
    if [ "${AUTO_DECRYPT_MODE:-0}" -eq 0 ]; then
        fresh_uuid="$(blkid -p -s UUID -o value "${ROOT_DEV}" 2>/dev/null || true)"
        if [ -n "${fresh_uuid}" ]; then
            ROOT_UUID="${fresh_uuid}"
        fi
        log "rootfs rebuilt via mkfs: ${ROOT_DEV}, label=armbi_root, UUID=${ROOT_UUID:-<empty>}"
    else
        log "rootfs rebuilt via mkfs on ${ROOT_DEV} (LUKS container untouched)"
    fi
    return 0
}

# ===== rebuild-or-clean rootfs + extract rootfs.tar.gz =====
# Returns 1 (caller unmounts+aborts) on reformat/clean/extract failure.
ota_apply_rootfs() {
    # Capture the pre-OTA env before the rootfs tar overwrites /boot content.
    # Only layouts without a boot.tar.gz payload keep the live env in rootfs
    # /boot; when a boot partition payload applies later, its capture in
    # ota_apply_boot is authoritative and overwrites this copy.
    # Must run before the mkfs rebuild: formatting drops the old /boot.
    if [ "${HAS_BOOT_TAR:-0}" -ne 1 ] && [ -f "${ROOT_MNT}/boot/armbianEnv.txt" ]; then
        if cp "${ROOT_MNT}/boot/armbianEnv.txt" "${LOGDIR}/armbianEnv.pre-ota"; then
            log "captured pre-OTA armbianEnv.txt from rootfs /boot"
        else
            log "WARN: failed to capture pre-OTA armbianEnv.txt from rootfs /boot"
        fi
    fi

    ota_reformat_rootfs
    fmt_rc=$?
    if [ "${fmt_rc}" -eq 2 ]; then
        log "ERROR: rootfs reformat failed irrecoverably, abort OTA"
        return 1
    fi

    if [ "${fmt_rc}" -ne 0 ]; then
        log "cleaning ${ROOT_MNT} (except boot)..."
        start_heartbeat "cleaning rootfs at ${ROOT_MNT}"
        (
            cd "${ROOT_MNT}" || exit 1
            for f in * .[!.]* ..?*; do
                case "$f" in
                    "."|".."|"boot")
                        continue
                        ;;
                esac
                rm -rf "$f"
            done
        ) || {
            stop_heartbeat
            log "ERROR: failed to clean ${ROOT_MNT}, abort OTA"
            return 1
        }
        stop_heartbeat
    fi

    log "extracting ${ROOTFS_TAR} -> ${ROOT_MNT} ..."
    start_heartbeat "extracting ${ROOTFS_TAR##*/} to ${ROOT_MNT}"
    if ! extract_tar "${ROOTFS_TAR}" "${ROOT_MNT}" "rootfs"; then
        stop_heartbeat
        log "ERROR: extract ${ROOTFS_TAR##*/} failed, abort OTA"
        return 1
    fi
    stop_heartbeat

    sync

    # Force-disable Armbian first-login marker after OTA. If new rootfs ships this
    # file, root login would trigger first-login flow unexpectedly.
    if rm -f "${ROOT_MNT}/root/.not_logged_in_yet" 2>/dev/null; then
        log "removed ${ROOT_MNT}/root/.not_logged_in_yet to avoid first-login re-trigger"
    fi

    # Clean stale getty autologin overrides. These are normally removed by
    # armbian-firstlogin; when firstlogin is skipped they may persist.
    for ov in \
        "${ROOT_MNT}/etc/systemd/system/getty@.service.d/override.conf" \
        "${ROOT_MNT}/etc/systemd/system/serial-getty@.service.d/override.conf"
    do
        if [ -f "${ov}" ]; then
            if grep -Eq -- 'autologin|--autologin' "${ov}" 2>/dev/null; then
                if rm -f "${ov}" 2>/dev/null; then
                    log "removed stale autologin override: ${ov}"
                else
                    log "WARN: failed to remove stale autologin override: ${ov}"
                fi
            else
                log "keep non-autologin override: ${ov}"
            fi
        fi
    done

    return 0
}

# ===== boot OTA: mount boot partition, extract boot.tar.gz, write boot.itb =====
# Returns 1 on boot.itb failure (caller unmounts+aborts). boot.tar.gz extract
# failure is logged but does not abort (matches legacy behavior).
ota_apply_boot() {
    # Hook mode: hook_pre_apply already performed the atomic boot swap and
    # left BOOT_MNT/DO_BOOT_OTA in place for ota_patch_config. Skip the
    # built-in extract entirely -- recomputing DO_BOOT_OTA here would clobber
    # the handoff (OTA_BOOT_HOOK_MODE set in ota_validate_recovery_state).
    if [ "${OTA_BOOT_HOOK_MODE:-0}" -eq 1 ]; then
        if [ "${DO_BOOT_OTA:-0}" -eq 1 ] && [ -n "${BOOT_MNT:-}" ]; then
            log "boot OTA handled by hook (BOOT_MNT=${BOOT_MNT} mounted for config patch)"
        else
            log "WARN: boot deferred to hook but no handoff (hook missing or failed); armbianEnv patch falls back to rootfs /boot"
        fi
        return 0
    fi

    DO_BOOT_OTA=0
    [ "$HAS_BOOT_PART" -eq 1 ] && [ "$HAS_BOOT_TAR" -eq 1 ] && DO_BOOT_OTA=1

    if [ "$DO_BOOT_OTA" -eq 1 ]; then
        log "boot OTA enabled (separate boot partition + ${BOOT_TAR##*/} present)"

        mkdir -p "${BOOT_MNT}"
        log "mounting ${BOOT_DEV} -> ${BOOT_MNT} ..."
        if ! mount -t ext4 -o rw "${BOOT_DEV}" "${BOOT_MNT}"; then
            log "ERROR: mount ${BOOT_DEV} failed, skip boot OTA"
            BOOT_MNT=""
            DO_BOOT_OTA=0
        fi
    else
        log "boot OTA disabled (no separate boot partition or no boot payload)"
    fi

    if [ "$DO_BOOT_OTA" -eq 1 ]; then
        # The separate boot partition holds the live env; capture it BEFORE
        # the clear below deletes it (hard ordering: capture -> clear ->
        # extract; inverting it loses the user's overlays, section 7 step 6).
        if [ -f "${BOOT_MNT}/armbianEnv.txt" ]; then
            if cp "${BOOT_MNT}/armbianEnv.txt" "${LOGDIR}/armbianEnv.pre-ota"; then
                log "captured pre-OTA armbianEnv.txt from boot partition"
            else
                log "WARN: failed to capture pre-OTA armbianEnv.txt from boot partition"
            fi
        fi

        # v0.8: wipe normal boot files (everything except recovery/ and
        # lost+found/, hidden files included) so the partition content after
        # OTA is exactly the package plus the rescuer. Never mkfs here --
        # recovery/ lives in this filesystem.
        ota_clear_normal_boot "${BOOT_MNT}" || {
            log "ERROR: failed to clear normal boot files"
            return 1
        }

        log "extracting ${BOOT_TAR} -> ${BOOT_MNT} ..."
        start_heartbeat "extracting ${BOOT_TAR##*/} to ${BOOT_MNT}"
        if ! extract_tar "${BOOT_TAR}" "${BOOT_MNT}" "boot"; then
            stop_heartbeat
            log "ERROR: extract ${BOOT_TAR##*/} failed -- FATAL (legacy warn-and-continue removed: it produced 'new rootfs + old boot')"
            return 1
        fi
        stop_heartbeat

        # v0.8: the package must prove its identity on the partition it just
        # wrote; a mismatch means the extract was partial or wrong.
        ota_verify_boot_marker "${BOOT_MNT}" || return 1

        sync
    fi

    if [ "${HAS_BOOT_ITB}" -eq 1 ]; then
        RAW_BOOT_DEV="$(find_raw_boot_dev || true)"
        if [ -z "${RAW_BOOT_DEV}" ]; then
            log "ERROR: boot.itb present but no PARTNAME=boot raw boot partition found"
            return 1
        fi
        if ! write_raw_boot_itb "${BOOT_ITB}" "${RAW_BOOT_DEV}"; then
            log "ERROR: raw boot.itb update failed, abort OTA"
            return 1
        fi
    fi

    return 0
}

# ===== fix UUIDs in armbianEnv.txt and new rootfs /etc/fstab (+ crypttab),
# then preserve pre-OTA user overlays in armbianEnv.txt =====
ota_patch_config() {
    if [ "$DO_BOOT_OTA" -eq 1 ] && [ -n "${BOOT_MNT}" ]; then
        ARM_ENV="${BOOT_MNT}/armbianEnv.txt"
    else
        ARM_ENV="${ROOT_MNT}/boot/armbianEnv.txt"
    fi

    FSTAB="${ROOT_MNT}/etc/fstab"
    CRYPTTAB="${ROOT_MNT}/etc/crypttab"

    # fallback UUID detection (just in case), anchored to the boot disk so a
    # clone disk with duplicate labels does not answer for the boot device
    _ota_disk="$(recovery_boot_disk || true)"
    if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
        [ -z "$ROOT_UUID" ] && ROOT_UUID="$(get_luks_uuid_for_root)"
    else
        [ -z "$ROOT_UUID" ] && ROOT_UUID="$(get_uuid_by_label "armbi_root" "${_ota_disk}")"
    fi
    [ -z "$BOOT_UUID" ] && BOOT_UUID="$(get_uuid_by_label "armbi_boot" "${_ota_disk}")"

    log "final ROOT_UUID=${ROOT_UUID}, BOOT_UUID=${BOOT_UUID}"

    # patch armbianEnv.txt if present
    if [ -f "${ARM_ENV}" ]; then
        log "patching ${ARM_ENV} ..."

        if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
            log "  - set rootdev=/dev/mapper/armbian-root"
            set_env_key "${ARM_ENV}" rootdev /dev/mapper/armbian-root
        else
            if [ -n "${ROOT_UUID}" ]; then
                log "  - set rootdev=UUID=${ROOT_UUID}"
                set_env_key "${ARM_ENV}" rootdev "UUID=${ROOT_UUID}"
            else
                log "  - WARN: ROOT_UUID empty, skip rootdev change"
            fi
        fi

        # Keep existing console settings. Overriding serial console here may break
        # user-observed boot logs/login on boards using different UARTs.
        if grep -q '^console=' "${ARM_ENV}"; then
            log "  - keep existing console setting"
        else
            log "  - no console= in armbianEnv, leave unchanged"
        fi

        # Keep armbianEnv.txt.dist in sync so the boot.scr fallback still
        # points at the current rootfs after OTA. Otherwise a later txt
        # corruption would fall back to a stale UUID and fail to rescue.
        # This runs BEFORE the overlays merge below so the .dist baseline
        # never absorbs user overlays.
        DIST_ENV="${ARM_ENV}.dist"
        if [ -f "${DIST_ENV}" ]; then
            log "syncing ${DIST_ENV} with new rootdev"
            if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
                set_env_key "${DIST_ENV}" rootdev /dev/mapper/armbian-root
            elif [ -n "${ROOT_UUID}" ]; then
                set_env_key "${DIST_ENV}" rootdev "UUID=${ROOT_UUID}"
            fi
            set_env_key "${DIST_ENV}" verbosity 6
        else
            log "  - ${DIST_ENV} missing, copying from ${ARM_ENV}"
            cp -a "${ARM_ENV}" "${DIST_ENV}"
        fi

        # Preserve user DT overlays across OTA: merge the pre-OTA overlays
        # value into the fresh baseline above. Baseline entries keep their
        # build-verified order (the RK3588 GPU stack overlay must stay
        # first-class for the desktop to come up); entries only present in
        # the old value are appended, deduplicated.
        OTA_OLD_ENV="${LOGDIR}/armbianEnv.pre-ota"
        if [ -f "${OTA_OLD_ENV}" ] && grep -q '^overlays=' "${OTA_OLD_ENV}"; then
            old_overlays="$(sed -n 's/^overlays=//p' "${OTA_OLD_ENV}" | tail -n 1)"
            new_overlays="$(sed -n 's/^overlays=//p' "${ARM_ENV}" | tail -n 1)"
            merged_overlays="$(printf '%s\n%s\n' "${new_overlays}" "${old_overlays}" |
                tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' |
                sed 's/[[:space:]]*$//')"
            if [ -n "${merged_overlays}" ]; then
                log "  - merge overlays: baseline='${new_overlays}' + pre-OTA='${old_overlays}' -> '${merged_overlays}'"
                set_env_key "${ARM_ENV}" overlays "${merged_overlays}"
            else
                log "  - pre-OTA overlays value empty, keep baseline overlays"
            fi
        else
            log "  - no pre-OTA overlays= line, keep baseline overlays"
        fi
    else
        log "WARN: ${ARM_ENV} not found, cannot patch rootdev/verbosity"
    fi

    # patch new rootfs /etc/fstab
    if [ -f "${FSTAB}" ]; then
        log "patching ${FSTAB} ..."

        if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
            log "  - update / entry to /dev/mapper/armbian-root"
            sed -i -E 's|^UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${FSTAB}"
            sed -i -E 's|^/dev/[^[:space:]]+[[:space:]]+/[[:space:]]+|/dev/mapper/armbian-root / |' "${FSTAB}"
        else
            if [ -n "${ROOT_UUID}" ]; then
                log "  - update / entry UUID to ${ROOT_UUID}"
                # lines like: UUID=xxxx / ext4 ...
                sed -i -E "s|^UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+|UUID=${ROOT_UUID} / |" "${FSTAB}"
            else
                log "  - WARN: ROOT_UUID empty, skip / fstab entry update"
            fi
        fi

        # Drop the /boot fstab entry: the initramfs mounts /boot anchored to
        # the rootfs disk (zz-seeed-mount-boot). Any fstab source is racy on
        # dd-cloned disks -- a UUID flips between clones through udev's
        # duplicate-UUID symlinks, and a hand-made /dev symlink never
        # satisfies systemd's udev-backed device unit. New packages already
        # lack the line (build hook 896), older ones still carry a UUID line.
        if grep -qE '^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)' "${FSTAB}"; then
            log "  - drop /boot entry (initramfs mounts /boot anchored)"
            sed -i -E '\@^[^[:space:]]+[[:space:]]+/boot([[:space:]]|$)@d' "${FSTAB}"
        fi
    else
        log "WARN: ${FSTAB} not found, skip fstab UUID patch"
    fi

    # patch new rootfs /etc/crypttab for auto-decrypt mode
    if [ "${AUTO_DECRYPT_MODE}" -eq 1 ]; then
        if [ -f "${CRYPTTAB}" ]; then
            if [ -n "${ROOT_UUID}" ]; then
                log "patching ${CRYPTTAB} ..."
                log "  - set armbian-root source UUID=${ROOT_UUID} (crypto_LUKS)"
                sed -i -E "s|^(armbian-root[[:space:]]+)UUID=[0-9a-fA-F-]+|\1UUID=${ROOT_UUID}|" "${CRYPTTAB}"
            else
                log "WARN: LUKS UUID empty, skip crypttab patch"
            fi
        else
            log "WARN: ${CRYPTTAB} not found, skip crypttab UUID patch"
        fi
    fi

    sync
}

# ===== write success state via state.sh helper =====
ota_commit_success_state() {
    mkdir -p "${STATE_DIR}"
    PACKAGE_PATH_VALUE="$(grep -E '^PACKAGE_PATH=' "${STATE_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    START_TIME_VALUE="$(grep -E '^START_TIME=' "${STATE_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    COMPLETE_TIME_VALUE="$(date -Iseconds)"
    if command -v ota_state_write_file >/dev/null 2>&1; then
        (
            OTA_STATE_MODE=recovery
            OTA_STATE_STATUS=success
            OTA_STATE_PACKAGE_PATH="${PACKAGE_PATH_VALUE}"
            OTA_STATE_START_TIME="${START_TIME_VALUE}"
            OTA_STATE_COMPLETE_TIME="${COMPLETE_TIME_VALUE}"
            ota_state_write_file "${STATE_FILE}"
        ) || log "WARN: failed to write ${STATE_FILE}"
    else
        log "WARN: state helper not available, failed to write ${STATE_FILE}"
    fi
}

# ===== unmount partitions (normal path; logs WARN on failure) =====
ota_unmount_all() {
    if [ "$DO_BOOT_OTA" -eq 1 ] && [ -n "${BOOT_MNT}" ]; then
        log "unmounting ${BOOT_MNT} ..."
        umount "${BOOT_MNT}" 2>/dev/null || log "WARN: umount ${BOOT_MNT} failed"
    fi

    log "unmounting ${ROOT_MNT} ..."
    umount "${ROOT_MNT}" 2>/dev/null  || log "WARN: umount ${ROOT_MNT} failed"
}

# ===== v0.8 helpers: boot clear, markers, overlay upper ======================

# Remove every normal boot file, keeping only recovery/ (the rescuer itself)
# and lost+found/. find -mindepth is mandatory: a shell glob would silently
# skip dotfiles (.auto_preserve etc.), section 7 "boot 清空规则".
ota_clear_normal_boot() {
    boot_mnt="$1"

    [ -n "${boot_mnt}" ] && [ -d "${boot_mnt}" ] || {
        log "ota_clear_normal_boot: invalid boot mount: ${boot_mnt:-<empty>}"
        return 1
    }

    log "clearing normal boot files in ${boot_mnt} (keeping recovery/, lost+found/)"
    find "${boot_mnt}" -mindepth 1 -maxdepth 1 \
        ! -name recovery ! -name lost+found \
        -exec rm -rf -- {} + || {
        log "ERROR: ota_clear_normal_boot: find/rm failed"
        return 1
    }
    sync
    return 0
}

# Boot marker gate: the payload identity the package carries must be present
# on the freshly written partition.
ota_verify_boot_marker() {
    boot_mnt="$1"
    expected="${OTA_EXPECT_PAYLOAD_ID:-}"

    [ -n "${expected}" ] || {
        log "ota_verify_boot_marker: OTA_EXPECT_PAYLOAD_ID not set by orchestrator"
        return 1
    }
    actual="$(cat "${boot_mnt}/payload-id" 2>/dev/null)"
    if [ "${actual}" != "${expected}" ]; then
        log "ERROR: boot payload marker mismatch: got=${actual:-none} want=${expected}"
        return 1
    fi
    log "boot payload marker verified: ${expected}"
    return 0
}

# Rootfs marker: the applier (not the tar) writes the identity into the new
# root so health confirmation can compare against CANDIDATE_ID. Backup-built
# payloads never carry it pre-stamped, so this write is unconditional.
ota_write_rootfs_marker() {
    marker_id="$1"

    mkdir -p "${ROOT_MNT}/usr/share/armbian-ota" || return 1
    printf '%s\n' "${marker_id}" > "${ROOT_MNT}/usr/share/armbian-ota/installed-payload-id" || {
        log "ERROR: cannot write rootfs payload marker"
        return 1
    }
    sync
    log "rootfs payload marker written: ${marker_id}"
    return 0
}

# Overlay upper cleanup (section 8): only the pieces that would shadow the
# new lower layer -- stale kernel modules and the old overlayroot config.
# Everything else in upper (user drift) survives by design.
ota_clean_overlay_upper() {
    upper="${USERDATA_MNT}/overlay"

    [ -d "${upper}" ] || {
        log "no overlay upper at ${upper}; skipping cleanup"
        return 0
    }
    rm -rf "${upper}/lib/modules" 2>/dev/null || {
        log "WARN: failed to clean ${upper}/lib/modules"
    }
    rm -f "${upper}/etc/overlayroot.conf" 2>/dev/null || {
        log "WARN: failed to clean ${upper}/etc/overlayroot.conf"
    }
    sync
    log "overlay upper cleaned (lib/modules, overlayroot.conf)"
    return 0
}
