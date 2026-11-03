#
# OTA hook: selective atomic boot-partition refresh (OTA_HOOK_API=1).
#
# Stage into a package with the build variables
#   OTA_HOOK_SCRIPT=<extension>/armbian-ota/recovery/hooks/boot-atomic-swap.sh
#   OTA_BOOT_REFRESH=0
# The flag lands in package.env and makes ota_validate_recovery_state defer
# the built-in boot extract (OTA_BOOT_HOOK_MODE=1), so this hook owns the
# boot partition instead of the legacy tar-over-live-files path.
#
# hook_pre_apply swaps only the files this board actually boots -- kernel
# three-piece set, board dtb (+ EEPROM-detectable family) and referenced
# overlays, boot.scr -- with a per-file "cp .swap_new + sync + rename"
# sequence, uInitrd (the only initramfs U-Boot loads) last. initrd.img-* is
# classified skip: the slim build hook (common/build-hooks/slim-initrd-img.sh)
# prunes it from the golden image and rk_secure_boot_find_ramdisk resolves
# ramdisks without it. Any power cut leaves every file wholly old or wholly
# new, so whichever initramfs engine boots next re-runs the prepared
# transaction and converges.
#
# armbianEnv.txt / .dist are never swapped here: the live env feeds the
# selection and is captured to ${LOGDIR}/armbianEnv.pre-ota for the
# orchestrator's ota_patch_config, which receives the mounted BOOT_MNT and
# DO_BOOT_OTA=1 handoff on success.
#
# BOOT_SWAP_FAIL_AFTER=<n> exits after n swaps, just before rename n+1
# (board-side power-cut test aid; production runs never set it).
#
# Sourced by 99-ota-apply into the orchestrator shell: expects extract_tar,
# log, start/stop_heartbeat and the ROOT_DEV/BOOT_DEV/HAS_BOOT_PART/OTA_DIR/
# BOOT_TAR/BOOT_MNT/LOGDIR globals. Definition-only, no side effects on
# source.

bsw_env_get() { # $1=key $2=env file
    sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -n1
}

# Classify a payload-relative path for this board:
# "critical" (swap last), "normal" (swap), or "skip" (leave alone).
bsw_classify() { # $1=rel $2=fdtfile $3=overlay_prefix
    case "$1" in
        armbianEnv.txt|armbianEnv.txt.dist) echo skip ;;
        System.map-*|config-*|boot.cmd)     echo skip ;;
        lost+found|.next|.list)             echo skip ;;
        # initrd.img-* was pruned from the golden image by
        # common/build-hooks/slim-initrd-img.sh (v0.8 patch #7); U-Boot only
        # loads uInitrd-*, so the raw file is dead weight on the wire and on
        # the partition. Older payloads may still carry it: skip, don't swap.
        initrd.img*)                        echo skip ;;
        boot.scr|boot.bmp)                  echo normal ;;
        uInitrd|uInitrd-*)                  echo critical ;;
        Image|vmlinuz*)                     echo normal ;;
        dtb)                                echo normal ;;
        dtb-*/"$2")                        echo normal ;;
        dtb-*/rockchip/*recomputer-rk*.dtb) echo normal ;;
        dtb-*/rockchip/overlay/*)
            if [ -n "$3" ]; then
                case "$1" in
                    dtb-*/rockchip/overlay/"$3"-*) echo normal ;;
                    *)                             echo skip ;;
                esac
            else
                echo skip
            fi
            ;;
        *) echo skip ;;
    esac
}

# Swap one file: identical -> skip; else stage .swap_new (free-space
# guarded, the copy coexists with the old file until the rename), sync,
# rename atomically, sync. Returns 1 on failure, exits 99 on the optional
# power-cut failpoint.
bsw_swap_one() { # $1=rel
    bsw_src="${bsw_work}/$1"
    bsw_dst="${BOOT_MNT}/$1"

    if [ -L "${bsw_src}" ]; then
        if [ -L "${bsw_dst}" ] && [ "$(readlink "${bsw_src}")" = "$(readlink "${bsw_dst}" 2>/dev/null)" ]; then
            log "boot-swap: skip(symlink-identical) $1"
            return 0
        fi
        bsw_need=4096
    else
        if [ -f "${bsw_dst}" ] && cmp -s "${bsw_src}" "${bsw_dst}"; then
            log "boot-swap: skip(identical) $1"
            return 0
        fi
        bsw_need=$(wc -c < "${bsw_src}")
    fi

    bsw_avail_kb=$(df -Pk "${BOOT_MNT}" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "${bsw_avail_kb}" ] && [ "$((bsw_avail_kb * 1024))" -lt "$((bsw_need + 16 * 1024 * 1024))" ]; then
        log "ERROR boot-swap: insufficient space for $1 (need ${bsw_need}B, avail ${bsw_avail_kb}KiB)"
        return 1
    fi

    mkdir -p "$(dirname "${bsw_dst}")"
    cp -a "${bsw_src}" "${bsw_dst}.swap_new" || {
        log "ERROR boot-swap: cp failed for $1"
        return 1
    }
    sync

    if [ -n "${BOOT_SWAP_FAIL_AFTER:-}" ]; then
        bsw_idx=$((bsw_idx + 1))
        if [ "${bsw_idx}" -ge "${BOOT_SWAP_FAIL_AFTER}" ]; then
            log "boot-swap: ~~POWER CUT~~ before rename of $1"
            exit 99
        fi
    fi

    mv "${bsw_dst}.swap_new" "${bsw_dst}" || {
        log "ERROR boot-swap: rename failed for $1"
        return 1
    }
    sync
    log "boot-swap: swapped $1"
    return 0
}

hook_pre_apply() {
    if [ "${HAS_BOOT_PART:-0}" -ne 1 ] || [ -z "${BOOT_DEV:-}" ]; then
        log "boot-swap: no separate boot partition, nothing to do"
        return 0
    fi
    if [ ! -f "${BOOT_TAR}" ]; then
        log "ERROR boot-swap: payload ${BOOT_TAR} missing"
        return 1
    fi

    mkdir -p "${BOOT_MNT}"
    if ! mount -t ext4 -o rw "${BOOT_DEV}" "${BOOT_MNT}"; then
        log "ERROR boot-swap: cannot mount ${BOOT_DEV} at ${BOOT_MNT}"
        return 1
    fi

    bsw_work="${OTA_DIR}/.bootswap"
    rm -rf "${bsw_work}"
    mkdir -p "${bsw_work}"
    start_heartbeat "boot atomic swap: extracting payload"
    if ! extract_tar "${BOOT_TAR}" "${bsw_work}" "bootswap"; then
        stop_heartbeat
        log "ERROR boot-swap: payload extract failed"
        rm -rf "${bsw_work}"
        umount "${BOOT_MNT}" 2>/dev/null
        return 1
    fi
    stop_heartbeat

    # Live env first (selection must follow the board as configured), the
    # payload env only as fallback; the capture feeds ota_patch_config.
    bsw_fdtfile=""
    bsw_prefix=""
    if [ -f "${BOOT_MNT}/armbianEnv.txt" ]; then
        cp "${BOOT_MNT}/armbianEnv.txt" "${LOGDIR}/armbianEnv.pre-ota"
        bsw_fdtfile="$(bsw_env_get fdtfile "${BOOT_MNT}/armbianEnv.txt")"
        bsw_prefix="$(bsw_env_get overlay_prefix "${BOOT_MNT}/armbianEnv.txt")"
    fi
    [ -n "${bsw_fdtfile}" ] || bsw_fdtfile="$(bsw_env_get fdtfile "${bsw_work}/armbianEnv.txt")"
    [ -n "${bsw_prefix}" ] || bsw_prefix="$(bsw_env_get overlay_prefix "${bsw_work}/armbianEnv.txt")"
    if [ -z "${bsw_fdtfile}" ]; then
        log "ERROR boot-swap: cannot resolve fdtfile from device or payload env"
        rm -rf "${bsw_work}"
        umount "${BOOT_MNT}" 2>/dev/null
        return 1
    fi
    log "boot-swap: fdtfile=${bsw_fdtfile} overlay_prefix=${bsw_prefix:-<none>}"

    # Stale .swap_new from an interrupted earlier run must not leak through.
    find "${BOOT_MNT}" -name '*.swap_new' -exec rm -f {} + 2>/dev/null

    find "${bsw_work}" -mindepth 1 \( -type f -o -type l \) |
        sed "s|^${bsw_work}/||" > "${bsw_work}/.list"

    bsw_idx=0
    bsw_failed=""
    for bsw_phase in normal critical; do
        while IFS= read -r bsw_rel; do
            [ -n "${bsw_rel}" ] || continue
            [ "$(bsw_classify "${bsw_rel}" "${bsw_fdtfile}" "${bsw_prefix}")" = "${bsw_phase}" ] || continue
            if ! bsw_swap_one "${bsw_rel}"; then
                bsw_failed=1
                break
            fi
        done < "${bsw_work}/.list"
        [ -n "${bsw_failed}" ] && break
    done

    if [ -n "${bsw_failed}" ]; then
        log "ERROR boot-swap: aborted, boot partition left in old/new per-file complete state (retry-safe)"
        rm -rf "${bsw_work}"
        umount "${BOOT_MNT}" 2>/dev/null
        return 1
    fi

    rm -rf "${bsw_work}"
    sync

    # Handoff: keep BOOT_MNT mounted and flag the orchestrator's config
    # patcher onto the boot partition (it patches armbianEnv in place).
    DO_BOOT_OTA=1
    log "boot-swap complete: BOOT_MNT=${BOOT_MNT} left mounted for ota_patch_config"
    return 0
}
