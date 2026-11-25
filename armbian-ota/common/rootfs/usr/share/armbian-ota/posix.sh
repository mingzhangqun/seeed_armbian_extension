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

# Call the named hook function if the hook defined it; a no-op otherwise.
# The function's return code is passed through.
ota_call_hook() {
    local fn="$1"
    shift

    type "${fn}" >/dev/null 2>&1 || return 0
    ota_lib_log "OTA hook point: ${fn}"
    "${fn}" "$@"
}

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
