#!/bin/sh
#
# Recovery initramfs source: logging, heartbeat, reboot.
#
# Sourced by 99-ota-apply (and future initramfs hooks). Self-contained:
# only needs /bin/sh + busybox userland. Sets LOGDIR/LOGFILE defaults that
# the caller may override before sourcing.

# ===== logging: file + /dev/kmsg =====
LOGDIR="${LOGDIR:-/run/initramfs}"
LOGFILE="${LOGFILE:-${LOGDIR}/ota.log}"

log() {
    echo "OTA_DEBG $*" >> "$LOGFILE" 2>/dev/null || true
    echo "OTA_DEBG $*" > /dev/kmsg 2>/dev/null || true
}

log_tail() {
    prefix="$1"
    file="$2"
    lines="${3:-40}"

    [ -s "${file}" ] || return 0
    tail -n "${lines}" "${file}" 2>/dev/null | while IFS= read -r l; do
        log "${prefix}: ${l}"
    done
}

# posix.sh logging adapter (shared with the bash rootfs runtime).
ota_lib_log() {
    log "$@"
}

# ===== heartbeat for long-running operations =====
HEARTBEAT_PID=""

start_heartbeat() {
    msg="$1"
    (
        while :; do
            echo "OTA_DEBG [HB] $msg" >> "$LOGFILE" 2>/dev/null || true
            echo "OTA_DEBG [HB] $msg" > /dev/kmsg 2>/dev/null || true
            sleep 10
        done
    ) &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [ -n "$HEARTBEAT_PID" ]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# ===== reboot (sysrq fallback, then reboot -f, then power-cycle spin) =====
ota_reboot() {
    log "OTA done, rebooting..."

    if [ -w /proc/sysrq-trigger ]; then
        echo b > /proc/sysrq-trigger
    fi

    if command -v reboot >/dev/null 2>&1; then
        reboot -f
    fi

    while :; do
        log "reboot failed, please power cycle"
        sleep 10
    done
}
