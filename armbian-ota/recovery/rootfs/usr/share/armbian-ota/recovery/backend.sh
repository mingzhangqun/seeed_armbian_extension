#!/bin/bash
#
# Recovery OTA userspace backend (v0.8 plain: trusted package + independent
# Rescue + last-good backup). Sourced by the armbian-ota CLI and by the
# health-check service; functions only, nothing executes at source time.
#
# Transaction layout on userdata (recovery-ota-backup-rollback-design.md
# section 4):
#   /media/root-rw/ota-recovery/
#     state/ota-state.env      authoritative transaction state
#     staging/                 in-flight extraction (never referenced)
#     payloads/<PAYLOAD_ID>/   candidate payload + last-good backup

RECOVERY_OVERLAY_BACKING_DIR="/media/root-rw"
RECOVERY_TRANSACTION_DIR="${RECOVERY_OVERLAY_BACKING_DIR}/ota-recovery"
OTA_PAYLOADS_DIR="${RECOVERY_TRANSACTION_DIR}/payloads"
OTA_STAGING_DIR="${RECOVERY_TRANSACTION_DIR}/staging"
OTA_WORK_DIR="${RECOVERY_TRANSACTION_DIR}/ota_work"   # legacy, kept for cleanup
OTA_STATE_DIR="${RECOVERY_TRANSACTION_DIR}/state"
OTA_STATE_FILE="${OTA_STATE_DIR}/ota-state.env"

# zstd settings for the on-device lazy backup creation (section 15.3): level 3
# keeps the CPU pass under the eMMC I/O floor, no --long (decompressor window
# cost outweighs the ratio for a once-per-device archive).
OTA_BACKUP_ZSTD_LEVEL="${OTA_BACKUP_ZSTD_LEVEL:--3}"
OTA_SPACE_MARGIN_MB="${OTA_SPACE_MARGIN_MB:-512}"
OTA_BACKUP_BOOT_EXCLUDES="recovery lost+found"

. /usr/share/armbian-ota/fwenv.sh

recovery_require_tools() {
    ota_require_runtime tar sha256sum mount umount mountpoint sed grep awk \
        find stat df zstd fw_setenv fw_printenv
}

recovery_require_transaction_store() {
    mountpoint -q "${RECOVERY_OVERLAY_BACKING_DIR}" ||
        error_exit "Recovery overlayroot backing store is unavailable: ${RECOVERY_OVERLAY_BACKING_DIR}"
}

# ===== system identity =======================================================

recovery_system_field() {
    local key="$1"

    sed -n "s/^${key}=//p" /etc/armbian-release 2>/dev/null | head -n1
}

recovery_lower_source() {
    findmnt -n -o SOURCE /media/root-ro 2>/dev/null ||
        findmnt -n -o SOURCE / 2>/dev/null
}

# ===== payload identity (keep in sync with package-create.sh build side) =====

# Deterministic tree hash over a boot staging tree: every file's sha256 in
# sorted path order, folded into one digest. payload-id itself is excluded so
# the ID never hashes its own container (section 4).
ota_payload_tree_hash() {
    local tree_dir="$1"

    (
        cd "${tree_dir}" || exit 1
        find . -type f ! -name payload-id -print0 | LC_ALL=C sort -z |
            xargs -0 -r sha256sum
    ) | awk '{print $1"  "substr($2,3)}' | sha256sum | awk '{print $1}'
}

ota_compute_payload_id() {
    local rootfs_tar="$1"
    local boot_tree="$2"
    local board="$3" release="$4" kernel="$5" version="$6"

    local root_sha boot_sha
    root_sha="$(sha256sum "${rootfs_tar}" | awk '{print $1}')"
    boot_sha="$(ota_payload_tree_hash "${boot_tree}")"

    printf 'armbian-ota-payload-v1|R=%s|B=%s|BOARD=%s|RELEASE=%s|KERNEL=%s|VERSION=%s|HAS_ROOTFS=1\n' \
        "${root_sha}" "${boot_sha}" "${board}" "${release}" "${kernel}" "${version}" |
        sha256sum | awk '{print $1}'
}

# ===== cheap pre-checks (15.2 step 1) ========================================

recovery_check_package_metadata() {
    local package_path="$1" force="$2"
    local payload_id board release

    payload_id="$(package_env_get_value "PAYLOAD_ID" || true)"
    [ -n "${payload_id}" ] ||
        error_exit "OTA package carries no PAYLOAD_ID (built by a pre-v0.8 toolchain); refused"

    board="$(package_env_get_value "BOARD" || true)"
    release="$(package_env_get_value "RELEASE" || true)"
    local sys_board sys_release
    sys_board="$(recovery_system_field BOARD)"
    sys_release="$(recovery_system_field RELEASE)"
    if [ -n "${sys_board}" ] && [ -n "${board}" ] && [ "${board}" != "${sys_board}" ]; then
        error_exit "OTA package BOARD mismatch: package=${board}, device=${sys_board}"
    fi
    if [ -n "${sys_release}" ] && [ -n "${release}" ] && [ "${release}" != "${sys_release}" ]; then
        error_exit "OTA package RELEASE mismatch: package=${release}, device=${sys_release} (cross-release OTA is not supported)"
    fi

    local installed_id
    installed_id="$(state_get INSTALLED_ID)"
    if [ -z "${force}" ] && [ -n "${installed_id}" ] && [ "${payload_id}" = "${installed_id}" ]; then
        error_exit "Payload ${payload_id} is already installed (INSTALLED_ID); use --force to reinstall the same version"
    fi

    OTA_CLI_PAYLOAD_ID="${payload_id}"
}

# KIND=full implies BOTH archives exist in the package and BOTH are covered
# by their checksum files. This is an explicit assertion, not a side effect
# of checksum verification: a broken build can drop boot.tar together with
# its checksum entry and still verify green (section 15.2).
recovery_assert_dual_tar() {
    local package_path="$1"
    local fmt member
    fmt="$(package_env_get_value "PAYLOAD_FORMAT" || echo "gz")"
    case "${fmt}" in
        xz)   fmt="xz" ;;
        zstd) fmt="zst" ;;
        gz)   fmt="gz" ;;
        *) error_exit "Unknown PAYLOAD_FORMAT: ${fmt}" ;;
    esac

    local listing
    listing="$(tar -tf "${package_path}" 2>/dev/null)" ||
        error_exit "Cannot list OTA package: ${package_path}"

    # final tarball members carry no ./ prefix (find -printf '%P'), but be
    # liberal and accept both spellings
    for member in "rootfs.tar.${fmt}" "boot.tar.${fmt}"; do
        printf '%s\n' "${listing}" | grep -qxE "(\./)?${member//./\\.}" ||
            error_exit "KIND=full package is missing ${member} (dual-tar assertion failed)"
    done
    for member in "rootfs.sha256" "boot.sha256"; do
        printf '%s\n' "${listing}" | grep -qxE "(\./)?${member//./\\.}" ||
            error_exit "OTA package is missing checksum file ${member} (dual-tar assertion failed)"
    done

    # each checksum file must actually cover its archive
    local root_sha boot_sha
    root_sha="$(tar -xOf "${package_path}" "rootfs.sha256" 2>/dev/null | grep -c "rootfs.tar.${fmt}" || true)"
    [ "${root_sha:-0}" -ge 1 ] || error_exit "rootfs.sha256 does not cover rootfs.tar.${fmt}"
    boot_sha="$(tar -xOf "${package_path}" "boot.sha256" 2>/dev/null | grep -c "boot.tar.${fmt}" || true)"
    [ "${boot_sha:-0}" -ge 1 ] || error_exit "boot.sha256 does not cover boot.tar.${fmt}"
}

recovery_check_space() {
    local package_path="$1" want_backup="$2"
    local avail need pkg_size backup_est=0 margin

    avail="$(df -B1 --output=avail "${RECOVERY_OVERLAY_BACKING_DIR}" 2>/dev/null | tail -n1)"
    [ -n "${avail}" ] || { log_warn "cannot read userdata free space; skipping space gate"; return 0; }

    pkg_size="$(stat -c%s "${package_path}")"
    need=$((pkg_size * 2))   # outer package + extracted payload members

    if [ "${want_backup}" = "yes" ]; then
        local lower_used boot_used
        lower_used="$(du -sb /media/root-ro 2>/dev/null | awk '{print $1}')"
        boot_used="$(du -sb /boot 2>/dev/null | awk '{print $1}')"
        backup_est=$(( ${lower_used:-0} + ${boot_used:-0} ))
        need=$((need + backup_est))
    fi

    margin=$((OTA_SPACE_MARGIN_MB * 1024 * 1024))
    if [ "${avail}" -lt $((need + margin)) ]; then
        error_exit "Insufficient userdata space: avail=${avail}, need=${need} (payload=${pkg_size}, backup_est=${backup_est}, margin=${margin}); use --no-backup to drop the backup term"
    fi
    log_info "Space gate: avail=${avail} need=${need} (backup_est=${backup_est})"
}

# ===== staging (15.2 steps 2 and 4) ==========================================

# Sweep payload directories that are neither the incoming candidate nor the
# current backup: an abandoned candidate (start re-entry) or a pre-rename
# orphan is GB-scale dead weight.
recovery_sweep_orphan_payloads() {
    local keep_ids="$1"
    local dir base

    [ -d "${OTA_PAYLOADS_DIR}" ] || return 0
    for dir in "${OTA_PAYLOADS_DIR}"/*; do
        [ -d "${dir}" ] || continue
        base="$(basename "${dir}")"
        case " ${keep_ids} " in
            *" ${base} "*) continue ;;
        esac
        log_info "Removing orphan payload directory: ${dir}"
        rm -rf "${dir}"
    done
    # legacy layout from pre-v0.8 runtime
    [ -d "${OTA_WORK_DIR}" ] && rm -rf "${OTA_WORK_DIR}"
    return 0
}

recovery_stage_payload() {
    local package_path="$1"
    local payload_id="${OTA_CLI_PAYLOAD_ID}"
    local incoming="${OTA_STAGING_DIR}/${payload_id}.incoming"

    mkdir -p "${OTA_STAGING_DIR}"
    rm -rf "${incoming}"

    log_info "Staging payload ${payload_id} (extract + full sha256 verification)"
    extract_ota_package "${package_path}" "${incoming}"
    ota_assert_payload_matches_system "${incoming}"
    ota_verify_payload "${incoming}" \
        "${OTA_PAYLOAD_ROOTFS_TAR}" "${OTA_PAYLOAD_ROOTFS_SHA}" \
        "${OTA_PAYLOAD_BOOT_TAR}" "${OTA_PAYLOAD_BOOT_SHA}" "${OTA_PAYLOAD_BOOT_ITB}"
    ota_check_package_requirements "${incoming}"
    ota_run_phase1_hooks "${incoming}"

    # payload.env: identity card of the staged directory (section 4). The
    # build stamps it; regenerate defensively if absent.
    if [ ! -f "${incoming}/payload.env" ]; then
        {
            echo "PAYLOAD_ID=${payload_id}"
            echo "KIND=full"
            echo "FMT=${OTA_PAYLOAD_ROOTFS_TAR##*.}"
            echo "HAS_ROOTFS=1"
            echo "BOARD=$(package_env_get_value "BOARD" || true)"
            echo "RELEASE=$(package_env_get_value "RELEASE" || true)"
            echo "KERNEL=$(package_env_get_value "KERNEL" || true)"
            echo "VERSION=$(package_env_get_value "VERSION" || true)"
            echo "OTA_MODE=recovery"
        } > "${incoming}/payload.env"
    fi

    sync
    mkdir -p "${OTA_PAYLOADS_DIR}"
    rm -rf "${OTA_PAYLOADS_DIR:?}/${payload_id}"
    mv "${incoming}" "${OTA_PAYLOADS_DIR}/${payload_id}" ||
        error_exit "Failed to move staged payload into place"
    sync
    log_info "Payload ${payload_id} staged at ${OTA_PAYLOADS_DIR}/${payload_id}"
}

# ===== lazy backup creation (15.2 step 3, 15.3) ==============================

recovery_backup_valid_structurally() {
    local dir="$1"

    [ -d "${dir}" ] || return 1
    [ -f "${dir}/payload.env" ] || return 1
    [ -f "${dir}/rootfs.tar.zst" ] || return 1
    [ -f "${dir}/boot.tar.zst" ] || return 1
    return 0
}

recovery_backup_needed() {
    local backup_id
    backup_id="$(state_get BACKUP_ID)"
    [ -z "${backup_id}" ] && return 0
    recovery_backup_valid_structurally "${OTA_PAYLOADS_DIR}/${backup_id}" && return 1
    return 0
}

# Create the last-good backup payload from the RUNNING system: lower rootfs
# partition content + boot partition content (recovery/ excluded). The upper
# layer survives OTA untouched, so lower+boot reproduces the full pre-OTA
# system on restore (section 15.1).
recovery_create_backup() {
    local lower_mnt="/media/root-ro"
    local boot_mnt="/boot"
    local work="${OTA_STAGING_DIR}/backup.$$"
    local lower_dev board release kernel version root_tar boot_tree payload_id

    recovery_require_transaction_store
    [ -d "${lower_mnt}" ] || error_exit "Backup source ${lower_mnt} missing (overlayroot lower not mounted)"
    mountpoint -q "${boot_mnt}" || error_exit "Backup source ${boot_mnt} is not a mounted boot partition"

    lower_dev="$(recovery_lower_source)"
    board="$(recovery_system_field BOARD)"
    release="$(recovery_system_field RELEASE)"
    kernel="$(uname -r)"
    version="$(recovery_system_field VERSION)"

    log_info "Creating last-good backup from running system (lower=${lower_dev}, ~minutes)"
    mkdir -p "${work}"
    local excludes=""
    local ex
    for ex in ${OTA_BACKUP_BOOT_EXCLUDES}; do
        excludes="${excludes} -name ${ex} -o"
    done
    excludes="${excludes% -o}"

    # 1) rootfs.tar.zst from the quiesced read-only lower layer
    log_info "Packing lower rootfs -> rootfs.tar.zst (zstd ${OTA_BACKUP_ZSTD_LEVEL})"
    if ! tar --numeric-owner --xattrs --acls -C "${lower_mnt}" -cf - . |
         zstd -q ${OTA_BACKUP_ZSTD_LEVEL} -T0 -o "${work}/rootfs.tar.zst"; then
        rm -rf "${work}"
        error_exit "Backup: failed to pack lower rootfs"
    fi
    (cd "${work}" && sha256sum rootfs.tar.zst > rootfs.sha256)

    # 2) boot staging tree: everything except recovery/ and lost+found/
    boot_tree="${work}/boot-tree"
    mkdir -p "${boot_tree}"
    (cd "${boot_mnt}" && find . -mindepth 1 -maxdepth 1 \( ${excludes} \) -prune -o -print0) |
        (cd "${boot_mnt}" && xargs -0 -r cp -a --target-directory="${boot_tree}")
    [ -f "${boot_tree}/Image" ] || {
        rm -rf "${work}"
        error_exit "Backup: boot staging tree missing Image"
    }

    # 3) identity, marker, boot.tar.zst
    payload_id="$(ota_compute_payload_id "${work}/rootfs.tar.zst" "${boot_tree}" \
        "${board}" "${release}" "${kernel}" "${version}")"
    printf '%s\n' "${payload_id}" > "${boot_tree}/payload-id"
    tar --numeric-owner -C "${boot_tree}" -cf - . |
        zstd -q ${OTA_BACKUP_ZSTD_LEVEL} -T0 -o "${work}/boot.tar.zst" ||
        { rm -rf "${work}"; error_exit "Backup: failed to pack boot tree"; }
    (cd "${work}" && sha256sum boot.tar.zst > boot.sha256)

    # 4) metadata
    {
        echo "PAYLOAD_ID=${payload_id}"
        echo "KIND=full"
        echo "FMT=zst"
        echo "HAS_ROOTFS=1"
        echo "BOARD=${board}"
        echo "RELEASE=${release}"
        echo "KERNEL=${kernel}"
        echo "VERSION=${version}"
        echo "OTA_MODE=recovery"
    } > "${work}/payload.env"
    {
        echo "# last-good backup of the running system"
        echo "CREATED=$(date -Iseconds)"
        echo "SOURCE_LOWER=${lower_dev}"
    } > "${work}/version.txt"

    # 5) atomic publish + record
    sync
    mkdir -p "${OTA_PAYLOADS_DIR}"
    rm -rf "${OTA_PAYLOADS_DIR:?}/${payload_id}"
    mv "${work}" "${OTA_PAYLOADS_DIR}/${payload_id}" ||
        { rm -rf "${work}"; error_exit "Backup: failed to publish payload directory"; }
    sync
    state_set "BACKUP_ID" "${payload_id}" ||
        error_exit "Backup: failed to persist BACKUP_ID"
    log_info "Last-good backup created: ${payload_id}"
}

# ===== env arm (15.2 step 5) ==================================================

recovery_arm_env() {
    local lower_dev disk

    lower_dev="$(recovery_lower_source)"
    disk="$(fw_env_ensure_config "${lower_dev}")" ||
        error_exit "Cannot resolve boot disk for fw_env (anchor=${lower_dev:-none})"

    fw_env_set_multi "ota_in_progress=1" "ota_boot_next=recovery" ||
        error_exit "Failed to arm U-Boot env (ota_in_progress=1, ota_boot_next=recovery); transaction NOT started"
    log_info "U-Boot env armed on ${disk}: ota_in_progress=1, ota_boot_next=recovery"
}

# ===== start ==================================================================

recovery_start_ota() {
    local package_path="$1"
    local force="${2:-}"
    local no_backup="${3:-}"

    [ -n "${package_path}" ] || error_exit "Usage: armbian-ota start [--force] [--no-backup] <ota-package>"
    [ -f "${package_path}" ] || error_exit "OTA package not found: ${package_path}"
    recovery_require_tools
    recovery_require_transaction_store
    assert_package_mode_matches "${package_path}" "recovery"

    # 1) cheap checks
    recovery_check_package_metadata "${package_path}" "${force}"
    recovery_assert_dual_tar "${package_path}"
    local want_backup="yes"
    [ -n "${no_backup}" ] && want_backup="no"
    recovery_check_space "${package_path}" "${want_backup}"

    # 2) full verification into staging (fail-fast, zero side effects)
    recovery_stage_payload "${package_path}"

    # 3) lazy backup (once per device lifetime)
    if [ "${want_backup}" = "yes" ] && recovery_backup_needed; then
        recovery_create_backup
    elif [ "${want_backup}" = "yes" ]; then
        log_info "Existing backup payload verified structurally: $(state_get BACKUP_ID)"
    fi

    # orphan sweep keeps userdata bounded to candidate + backup
    recovery_sweep_orphan_payloads "${OTA_CLI_PAYLOAD_ID} $(state_get BACKUP_ID)"

    # 4) begin campaign (abandons any unfinished transaction by definition)
    state_begin_campaign "${OTA_CLI_PAYLOAD_ID}"
    log_info "Campaign prepared: candidate=${OTA_CLI_PAYLOAD_ID} backup=$(state_get BACKUP_ID)"

    # 5) arm env LAST
    recovery_arm_env

    log_info "Recovery OTA armed. Reboot to apply in Rescue."
    log_info "After reboot the transaction auto-commits; power loss is safe at any point."
}

# ===== terminal commit (health pass or mark-success) ==========================

# Roll the backup pointer to the freshly confirmed payload (15.5): state
# first, delete the old directory second -- any power cut leaves BACKUP_ID
# pointing at a complete payload directory.
recovery_roll_backup() {
    local candidate_id="$1"
    local old_backup new_dir old_dir

    old_backup="$(state_get BACKUP_ID)"
    [ "${old_backup}" = "${candidate_id}" ] && return 0   # restore campaign: no-op

    new_dir="${OTA_PAYLOADS_DIR}/${candidate_id}"
    [ -d "${new_dir}" ] || {
        log_warn "Confirmed payload ${candidate_id} is not staged; keeping backup ${old_backup:-none}"
        return 0
    }

    state_set "BACKUP_ID" "${candidate_id}" || return 1
    if [ -n "${old_backup}" ] && [ "${old_backup}" != "${candidate_id}" ]; then
        old_dir="${OTA_PAYLOADS_DIR}/${old_backup}"
        [ -d "${old_dir}" ] && rm -rf "${old_dir}"
    fi
    sync
    log_info "Backup rolled to ${candidate_id} (previous: ${old_backup:-none})"
    return 0
}

# Shared terminal commit: health confirmation passed (auto or mark-success).
recovery_commit_success() {
    local candidate_id restore_mode

    recovery_require_transaction_store

    candidate_id="$(state_get CANDIDATE_ID)"
    restore_mode="$(state_get RESTORE_MODE)"
    [ -n "${candidate_id}" ] || error_exit "No CANDIDATE_ID in state; nothing to confirm"

    state_mark_success "${candidate_id}"
    recovery_roll_backup "${candidate_id}"

    local lower_dev
    lower_dev="$(recovery_lower_source)"
    fw_env_ensure_config "${lower_dev}" >/dev/null ||
        error_exit "Cannot resolve boot disk for fw_env; env NOT cleared"
    fw_env_set "ota_in_progress" "0" ||
        error_exit "Failed to clear ota_in_progress; next boot routes to Rescue (harmless, will self-reconcile)"

    rm -rf "${OTA_STAGING_DIR}"/* 2>/dev/null || true
    log_info "OTA transaction committed: INSTALLED_ID=${candidate_id} RESTORE_MODE=${restore_mode}"
}

recovery_mark_success() {
    local in_progress status

    init_logging
    acquire_lock || error_exit "Cannot acquire OTA lock"
    recovery_require_transaction_store

    in_progress="$(fw_env_get ota_in_progress)"
    status="$(state_get STATUS)"
    if [ "${in_progress}" != "1" ] || [ "${status}" != "applied" ]; then
        error_exit "mark-success requires an active applied transaction (env ota_in_progress=${in_progress:-unset}, STATUS=${status:-none})"
    fi

    recovery_commit_success
    log_info "OTA marked successful by operator $(logname 2>/dev/null || echo unknown) at $(date -Iseconds)"
}

recovery_rollback() {
    error_exit "Rollback is not a user command in recovery mode; recovery happens automatically when retries are exhausted (v0.8 design section 15.4)"
}

# ===== status ==================================================================

recovery_status() {
    local status installed backup candidate restore retry touched err

    state_init
    status="$(state_get STATUS)"
    installed="$(state_get INSTALLED_ID)"
    backup="$(state_get BACKUP_ID)"
    candidate="$(state_get CANDIDATE_ID)"
    restore="$(state_get RESTORE_MODE)"
    retry="$(state_get RETRY_COUNT)"
    touched="$(state_get ROOTFS_TOUCHED)"
    err="$(state_get ERROR_MSG)"

    echo "=== Armbian OTA Status (Recovery) ==="
    echo "Mode: recovery (plain v0.8)"
    echo "Status: ${status}"
    echo "Installed payload: ${installed:-none}"
    echo "Last-good backup: ${backup:-none}"
    if [ "${status}" = "success" ] && [ "${restore}" = "1" ] && [ -n "${backup}" ]; then
        echo "Restored: yes (system rolled back to backup ${backup})"
    fi
    if [ -n "${candidate}" ] && [ "${status}" != "success" ]; then
        echo "Candidate: ${candidate} (restore_mode=${restore}, retry=${retry}, rootfs_touched=${touched})"
    fi
    [ -n "${err}" ] && echo "Last error: ${err}"
    echo "Prepared at: $(state_get START_TIME)"
    echo ""
    echo "U-Boot env:"
    if fw_env_ensure_config "$(recovery_lower_source)" >/dev/null 2>&1; then
        echo "  ota_in_progress=$(fw_env_get ota_in_progress || echo unset)"
        echo "  ota_boot_next=$(fw_env_get ota_boot_next || echo unset)"
    else
        echo "  unavailable (boot disk not resolvable)"
    fi
    echo ""
    echo "Payload store: ${OTA_PAYLOADS_DIR}"
    local dir
    for dir in "${OTA_PAYLOADS_DIR}"/*; do
        [ -d "${dir}" ] || continue
        local id size
        id="$(basename "${dir}")"
        size="$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')"
        local role="candidate"
        [ "${id}" = "${backup}" ] && role="last-good backup"
        [ "${id}" = "${installed}" ] && role="installed"
        echo "  ${id} (${size}, ${role})"
    done
}
