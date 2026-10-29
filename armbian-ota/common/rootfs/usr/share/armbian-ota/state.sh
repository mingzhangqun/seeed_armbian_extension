#!/bin/sh

# OTA runtime state (v0.8 plain recovery layout, A/B legacy fields kept).
#
# The state file is the single source of truth for an OTA transaction
# (recovery-ota-backup-rollback-design.md section 5): U-Boot env only carries
# routing tokens, payload markers prove on-disk content, and every decision
# after a reboot is re-derived from this file. Writes are atomic:
# tmp -> sync -> rename -> sync, so a power cut can never leave a half
# written key set (the rename is the commit point).
#
# POSIX sh + busybox userland (sourced by the initramfs apply hook and by
# bash rootfs tooling alike).

OTA_STATE_DIR="${OTA_STATE_DIR:-/var/lib/armbian-ota}"
OTA_STATE_FILE="${OTA_STATE_FILE:-${OTA_STATE_DIR}/ota-state.env}"

# Persist the current key set atomically. Input file $1 already holds the
# complete new content; it is fsynced (via sync), renamed over the state file
# and the directory entry synced again.
ota_state_commit_tmp() {
    tmp_file="$1"

    sync
    if ! mv "${tmp_file}" "${OTA_STATE_FILE}"; then
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    fi
    sync
    return 0
}

# Rewrite key=$2 to value=$3 atomically (single-key form).
ota_state_set_key() {
    state_file="$1"
    key="$2"
    value="$3"
    tmp_file="${OTA_STATE_FILE}.tmp.$$"

    {
        grep -v "^${key}=" "${state_file}" 2>/dev/null
        printf '%s=%s\n' "${key}" "${value}"
    } > "${tmp_file}" || {
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }

    ota_state_commit_tmp "${tmp_file}"
}

# Set multiple keys in ONE atomic write: ota_state_set_multi K1=V1 K2=V2 ...
# Used at transaction boundaries (prepared header, restore-mode switch,
# success commit) where a power cut between individual writes would leave a
# state no branch of the reconciliation table can re-derive.
ota_state_set_multi() {
    tmp_file="${OTA_STATE_FILE}.tmp.$$"
    keys=""

    for kv in "$@"; do
        keys="${keys} ${kv%%=*}"
    done

    {
        # drop every key about to be rewritten, keep the rest verbatim
        awk -v drop="${keys# }" '
            BEGIN { n = split(drop, k, / +/) }
            {
                for (i = 1; i <= n; i++) {
                    if (index($0, k[i] "=") == 1) next
                }
                print
            }
        ' "${OTA_STATE_FILE}" 2>/dev/null
        for kv in "$@"; do
            printf '%s\n' "${kv}"
        done
    } > "${tmp_file}" || {
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }

    ota_state_commit_tmp "${tmp_file}"
}

ota_state_write_file() {
    state_file="$1"
    state_dir="${state_file%/*}"

    mkdir -p "${state_dir}" || return 1
    cat > "${state_file}" <<'EOF' || return 1
# Armbian OTA runtime state
OTA_MODE=
STATUS=idle
PACKAGE_PATH=
CURRENT_SLOT=
TARGET_SLOT=
START_TIME=
COMPLETE_TIME=
CANDIDATE_ID=
INSTALLED_ID=
BACKUP_ID=
RESTORE_MODE=0
ROOTFS_TOUCHED=0
RETRY_COUNT=0
ERROR_MSG=
EOF

    ota_state_set_key "${state_file}" OTA_MODE "${OTA_STATE_MODE:-}" || return 1
    ota_state_set_key "${state_file}" STATUS "${OTA_STATE_STATUS:-idle}" || return 1
    ota_state_set_key "${state_file}" PACKAGE_PATH "${OTA_STATE_PACKAGE_PATH:-}" || return 1
    ota_state_set_key "${state_file}" CURRENT_SLOT "${OTA_STATE_CURRENT_SLOT:-}" || return 1
    ota_state_set_key "${state_file}" TARGET_SLOT "${OTA_STATE_TARGET_SLOT:-}" || return 1
    ota_state_set_key "${state_file}" START_TIME "${OTA_STATE_START_TIME:-}" || return 1
    ota_state_set_key "${state_file}" COMPLETE_TIME "${OTA_STATE_COMPLETE_TIME:-}" || return 1
}

state_init() {
    mkdir -p "${OTA_STATE_DIR}" 2>/dev/null || return 1
    [ -f "${OTA_STATE_FILE}" ] && return 0

    (
        OTA_STATE_STATUS=idle
        ota_state_write_file "${OTA_STATE_FILE}"
    )
}

state_get() {
    key="$1"

    if [ -f "${OTA_STATE_FILE}" ]; then
        grep -E "^${key}=" "${OTA_STATE_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2-
    fi
}

state_set() {
    key="$1"
    value="$2"

    state_init || return 1
    ota_state_set_key "${OTA_STATE_FILE}" "${key}" "${value}"
}

state_mark_mode() {
    state_set "OTA_MODE" "$1"
}

state_mark_status() {
    state_set "STATUS" "$1"
}

state_mark_prepared() {
    mode="$1"
    status="$2"
    package_path="$3"
    current_slot="${4:-}"
    target_slot="${5:-}"

    state_init || return 1
    state_mark_mode "${mode}" || return 1
    state_mark_status "${status}" || return 1
    state_set "PACKAGE_PATH" "$(basename "${package_path}")" || return 1
    state_set "CURRENT_SLOT" "${current_slot}" || return 1
    state_set "TARGET_SLOT" "${target_slot}" || return 1
    state_set "START_TIME" "$(date -Iseconds)" || return 1
    state_set "COMPLETE_TIME" "" || return 1
}

state_mark_completed() {
    mode="$1"
    status="$2"
    current_slot="${3:-}"
    target_slot="${4:-}"

    state_init || return 1
    state_mark_mode "${mode}" || return 1
    state_mark_status "${status}" || return 1
    state_set "CURRENT_SLOT" "${current_slot}" || return 1
    state_set "TARGET_SLOT" "${target_slot}" || return 1
    state_set "COMPLETE_TIME" "$(date -Iseconds)" || return 1
}

# ===== v0.8 plain recovery helpers ==========================================

# Begin a new campaign (start or restore switch). One atomic header write:
# any earlier unfinished transaction is abandoned by definition (section 7,
# start re-entry). ERROR_MSG is cleared with the new campaign.
state_begin_campaign() {
    candidate_id="$1"

    ota_state_set_multi \
        "OTA_MODE=recovery" \
        "STATUS=prepared" \
        "CANDIDATE_ID=${candidate_id}" \
        "ROOTFS_TOUCHED=0" \
        "RETRY_COUNT=0" \
        "RESTORE_MODE=0" \
        "ERROR_MSG=" \
        "START_TIME=$(date -Iseconds)" \
        "COMPLETE_TIME="
}

# Switch the exhausted candidate campaign to the backup payload (15.4).
# Written before any status change to failed: the branch is a pure function
# of (RETRY==MAX, backup valid, RESTORE_MODE) so a power cut here simply
# re-derives the same decision on the next Rescue boot.
state_switch_restore() {
    backup_id="$1"
    reason="$2"

    ota_state_set_multi \
        "STATUS=prepared" \
        "CANDIDATE_ID=${backup_id}" \
        "RESTORE_MODE=1" \
        "RETRY_COUNT=0" \
        "ROOTFS_TOUCHED=0" \
        "ERROR_MSG=${reason}"
}

state_mark_failed() {
    reason="$1"

    ota_state_set_multi \
        "STATUS=failed" \
        "ERROR_MSG=${reason}" \
        "COMPLETE_TIME=$(date -Iseconds)"
}

# Terminal commit on health confirmation success: INSTALLED_ID first, then
# the caller rolls the backup pointer (15.5) and clears ota_in_progress.
state_mark_success() {
    installed_id="$1"

    ota_state_set_multi \
        "STATUS=success" \
        "INSTALLED_ID=${installed_id}" \
        "COMPLETE_TIME=$(date -Iseconds)"
}
