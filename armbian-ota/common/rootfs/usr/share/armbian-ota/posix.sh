#!/bin/sh
#
# POSIX-safe helpers shared by the bash rootfs runtime and the busybox
# initramfs; logging goes through ota_lib_log, defined per environment.

# OTA hook contract constants (single source for both environments).
OTA_HOOK_API="1"
OTA_HOOK_DEFAULT_NAME="ota-hook.sh"
# Pre-1.2 packages may still carry the narrow "apply hook" name/declaration.
OTA_HOOK_LEGACY_NAME="ota-apply-hook.sh"

# Resolve the staged hook filename: declared OTA_HOOK (legacy OTA_APPLY_HOOK
# accepted) wins, then the conventional name, then the legacy one.
ota_resolve_hook_name() {
    local dir="$1" declared

    if [ -f "${dir}/package.env" ]; then
        declared="$(sed -n 's/^OTA_HOOK=//p' "${dir}/package.env" | head -n1)"
        if [ -z "${declared}" ]; then
            declared="$(sed -n 's/^OTA_APPLY_HOOK=//p' "${dir}/package.env" | head -n1)"
        fi
    fi
    if [ -n "${declared}" ] && [ -f "${dir}/${declared}" ]; then
        printf '%s\n' "${declared}"
        return 0
    fi
    if [ -f "${dir}/${OTA_HOOK_DEFAULT_NAME}" ]; then
        printf '%s\n' "${OTA_HOOK_DEFAULT_NAME}"
        return 0
    fi
    if [ -f "${dir}/${OTA_HOOK_LEGACY_NAME}" ]; then
        printf '%s\n' "${OTA_HOOK_LEGACY_NAME}"
        return 0
    fi
    return 1
}

# First blkid match for KEY=value, scoped to partitions of $disk; clones
# duplicate labels/UUIDs, so callers pass the boot disk.
ota_blkid_first_on_disk() {
    local filter="$1" disk="$2"

    if [ -n "${disk}" ]; then
        blkid -t "${filter}" -o device 2>/dev/null |
            grep -E "^${disk}p[0-9]+$" | head -n1
    else
        blkid -t "${filter}" -o device 2>/dev/null | head -n1
    fi
}

# Call the named hook function if the hook defined it; a no-op otherwise.
# The function's return code is passed through.
ota_call_hook() {
    local fn="$1"
    shift

    type "${fn}" >/dev/null 2>&1 || return 0
    ota_lib_log "OTA hook point: ${fn}"
    "${fn}" "$@"
}

# Effective (last-wins) value of a key in an env file, empty if absent.
ota_env_get_key() {
    local env_file="$1" key="$2"

    [ -f "${env_file}" ] || return 0
    sed -n "s/^${key}=//p" "${env_file}" | tail -n 1
}

# Set (replace or append) a key in an env file; rc 1 on write failure.
ota_env_set_key() {
    local env_file="$1" key="$2" value="$3"

    if grep -q "^${key}=" "${env_file}"; then
        sed -i "s|^${key}=.*$|${key}=${value}|" "${env_file}" || return 1
    else
        printf '\n%s=%s\n' "${key}" "${value}" >> "${env_file}" || return 1
    fi
}

# Merge two whitespace-separated overlay lists: baseline entries keep their
# order, old-only entries are appended, deduplicated.
ota_merge_overlays() {
    local new="$1" old="$2"

    printf '%s\n%s\n' "${new}" "${old}" |
        tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' |
        sed 's/[[:space:]]*$//'
}

# Chunked exact-extent read streamed into sha256sum; the status side file
# carries the read result (POSIX sh has no pipefail). $4 is the scratch dir.
ota_fit_readback_verify() (
    fit_target="$1"
    fit_size="$2"
    fit_expected_sha="$3"
    fit_dir="$4"
    fit_status="${fit_dir}/fit-readback.status.$$"
    fit_sha_file="${fit_dir}/fit-readback.sha256.$$"

    [ -d "${fit_dir}" ] || mkdir -p "${fit_dir}" 2>/dev/null || return 1
    rm -f "${fit_status}" "${fit_sha_file}" 2>/dev/null || true

    fit_remaining="${fit_size}"
    fit_offset=0
    {
        while [ "${fit_remaining}" -gt 0 ]; do
            fit_chunk="${fit_remaining}"
            [ "${fit_chunk}" -gt 1048576 ] && fit_chunk=1048576
            if [ "${fit_chunk}" -eq 1048576 ]; then
                dd if="${fit_target}" bs=1M skip=$((fit_offset / 1048576)) \
                    count=1 iflag=fullblock status=none || break
            else
                dd if="${fit_target}" bs=1 skip="${fit_offset}" count="${fit_chunk}" \
                    iflag=fullblock status=none || break
            fi
            fit_offset=$((fit_offset + fit_chunk))
            fit_remaining=$((fit_remaining - fit_chunk))
        done
        printf '%s\n' "${fit_remaining}" > "${fit_status}"
    } | sha256sum | awk '{print $1}' > "${fit_sha_file}"

    fit_actual_sha="$(cat "${fit_sha_file}" 2>/dev/null)"
    fit_read_rc=1
    [ -f "${fit_status}" ] && fit_read_rc="$(cat "${fit_status}" 2>/dev/null)"
    rm -f "${fit_status}" "${fit_sha_file}" 2>/dev/null || true
    if [ "${fit_read_rc}" != "0" ] || [ "${fit_actual_sha}" != "${fit_expected_sha}" ]; then
        ota_lib_log "ERROR: written FIT readback failed or does not match source"
        return 1
    fi
    return 0
)

# FIT image check: d00dfeed magic in the first 4 bytes.
ota_is_fit_image() {
    local image="$1" magic

    [ -f "${image}" ] || return 1
    magic="$(dd if="${image}" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "${magic}" = "d00dfeed" ]
}

# Full-content verification of a payload directory: payload.env presence
# plus the rootfs/boot sha256 manifests.
ota_payload_verify_full() {
    local dir="$1"

    [ -d "${dir}" ] || return 1
    [ -f "${dir}/payload.env" ] || return 1
    (cd "${dir}" && sha256sum -c rootfs.sha256 >/dev/null 2>&1) || {
        ota_lib_log "payload verification: rootfs.sha256 failed for ${dir}"
        return 1
    }
    (cd "${dir}" && sha256sum -c boot.sha256 >/dev/null 2>&1) || {
        ota_lib_log "payload verification: boot.sha256 failed for ${dir}"
        return 1
    }
    return 0
}
