#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
BOARD="recomputer-rk3576-devkit"
BRANCH="${BRANCH:-vendor}"
RELEASE="bookworm"
KERNEL_CONFIGURE="no"
CLEAR_KERNEL_CACHE="no"
CLEAR_ROOTFS_CACHE="no"
DRY_RUN="no"
ENABLE_SEEED_RK_EXTENSION="yes"
DESKTOP_ENVIRONMENT="gnome"
DESKTOP_TIER="mid"

# Build mode
BUILD_KERNEL_ONLY="no"
BUILD_UBOOT_ONLY="no"
BUILD_MINIMAL="no"
BUILD_DESKTOP="yes"

# Feature flags. Empty OTA_ENABLE means "honor board config default".
OTA_ENABLE=""
AB_PART_OTA="no"
# Empty OTA_PAYLOAD_COMP falls back to the extension's central default (xz).
# Preserves a pre-exported value so env override works alongside --ota-format.
OTA_PAYLOAD_COMP="${OTA_PAYLOAD_COMP:-}"
SECURITY_PROFILE="none"

RK_COMPILE_USBPLUG="yes"

# Everything after `--` on the command line goes verbatim to compile.sh.
EXTRA_PASSTHROUGH=()

CRYPTROOT_PASSPHRASE="${CRYPTROOT_PASSPHRASE:-}"

# Valid option values
VALID_BOARDS="recomputer-rk3576-devkit recomputer-rk3588-devkit recomputer-rk3576-industrial recomputer-rk3576-module-devkit"
VALID_DESKTOPS="gnome xfce kde-plasma mate cinnamon"
VALID_TIERS="minimal mid full"
VALID_OTA_FORMATS="xz gz zstd"

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [profile ...] [options]

Profiles (feature switches, can be combined; default: plain desktop build):
  recovery      Recovery OTA
  ab            A/B dual-partition OTA
  secure-rootfs LUKS root + OP-TEE/SSKR automatic unlock
  secure-boot   Secure U-Boot + secure-rootfs

Options:
  Build mode:
  --kernel                    Build kernel only (skip u-boot, rootfs, image)
  --uboot                     Build u-boot only (skip kernel, rootfs, image)
  --minimal                   Build minimal system (no desktop)

  Build config:
  -b, --board BOARD           Board name (default: recomputer-rk3576-devkit)
                              Options: recomputer-rk3576-devkit, recomputer-rk3588-devkit,
                                       recomputer-rk3576-industrial, recomputer-rk3576-module-devkit
  -R, --release RELEASE       Release/distro (default: bookworm)
                              Debian:  trixie, bookworm, bullseye, buster, sid, forky, resolute
                              Ubuntu:  plucky, oracular, noble, jammy, focal, questing
  -d, --desktop DE            Desktop environment (default: gnome)
                              Options: gnome, xfce, kde-plasma, mate, cinnamon
  -t, --tier TIER             Desktop tier (default: mid)
                              Options: minimal, mid, full
      --ota-format FORMAT     OTA package payload format (default: xz)
                              Options: xz, gz, zstd

  Utilities:
  --no-usbplug                Skip usbplug recompile (use rkbin blob; old SPI flash only)
  -c, --clear-kernel-cache    Clear kernel deb/worktree cache before build
  -r, --clear-rootfs-cache    Clear rootfs cache before build
  -n, --dry-run               Show build config without running compile.sh
  -h, --help                  Show this help
  --                          Pass everything after it verbatim to compile.sh
                              (userpatches config names, KEY=VALUE overrides)

Examples:
  $(basename "$0")                              # Default: GNOME desktop, bookworm
  $(basename "$0") -d xfce -R noble             # XFCE on Ubuntu noble
  $(basename "$0") --minimal                    # No desktop, minimal system
  $(basename "$0") --kernel -c                  # Kernel only, clear cache
  $(basename "$0") recovery                     # Recovery OTA only
  $(basename "$0") secure-rootfs --minimal      # Encrypted rootfs with automatic unlock
  $(basename "$0") recovery secure-boot         # Recovery OTA + secure boot
  $(basename "$0") ab secure-boot -d xfce       # A/B OTA + secure boot with XFCE
  $(basename "$0") ab -b recomputer-rk3588-devkit
  $(basename "$0") --minimal -- OTA_ENABLE=no industrial-local
EOF
    exit 0
}

# ── Helpers ─────────────────────────────────────────────────────────────────
die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

validate_option() {
    local name="$1" value="$2" valid="$3"
    if ! echo " $valid " | grep -q " $value "; then
        die "Invalid $name '$value'. Valid options: $valid"
    fi
}

clear_uboot_cache() {
    # Full secure boot changes both the Debian package and artifact names by
    # appending "-secure".  Keep the other variant intact so one workflow can
    # produce and publish both packages.
    local variant_suffix=""
    if [[ "$SECURITY_PROFILE" == "secure-boot" ]]; then
        variant_suffix="-secure"
    fi

    local package_name="linux-u-boot-${BOARD}-${BRANCH}${variant_suffix}"
    local artifact_name="uboot-${BOARD}-${BRANCH}${variant_suffix}"

    echo "Clearing U-Boot artifact cache for ${package_name}..."
    rm -f "output/debs/${package_name}_"*.deb
    rm -f "output/packages-hashed/${artifact_name}_"*.tar 2>/dev/null
    echo "U-Boot cache cleared."
}

# ── Profile application ─────────────────────────────────────────────────────
apply_profile() {
    local profile="${1:-}"
    [[ -z "$profile" ]] && return 0
    case "$profile" in
        recovery)
            OTA_ENABLE="yes"
            AB_PART_OTA="no"
            ;;
        ab)
            OTA_ENABLE="yes"
            AB_PART_OTA="yes"
            ;;
        secure-rootfs)
            SECURITY_PROFILE="secure-rootfs"
            ;;
        secure-boot)
            SECURITY_PROFILE="secure-boot"
            ;;
        *)
            die "Unknown profile '$profile'. Run '$(basename "$0") --help' for available profiles."
            ;;
    esac
}

append_security_args() {
    local require_passphrase="${1:-no}"

    [[ "$SECURITY_PROFILE" == "none" ]] && return 0

    if [[ "$require_passphrase" == "yes" ]]; then
        [[ -z "$CRYPTROOT_PASSPHRASE" ]] && die "CRYPTROOT_PASSPHRASE is required for encrypted builds. Set it in environment."
        # Keep this out of argv and build logs. The Docker extension forwards the
        # already-exported variable using `--env CRYPTROOT_PASSPHRASE`.
        export CRYPTROOT_PASSPHRASE
        BUILD_CMD+=(CRYPTROOT_ENABLE=yes)
    else
        BUILD_CMD+=(CRYPTROOT_ENABLE=yes)
    fi

    BUILD_CMD+=(RK_AUTO_DECRYP=yes)

    case "$SECURITY_PROFILE" in
        secure-rootfs)
            BUILD_CMD+=(RK_OPTEE_BOOT_ENABLE=yes)
            ;;
        secure-boot)
            BUILD_CMD+=(RK_SECURE_UBOOT_ENABLE=yes)
            ;;
        *)
            die "Unknown security profile '$SECURITY_PROFILE'."
            ;;
    esac
    return 0
}

append_cache_ttl_args() {
    [[ -n "${UBOOT_GIT_CACHE_TTL:-}" ]] && BUILD_CMD+=(UBOOT_GIT_CACHE_TTL="$UBOOT_GIT_CACHE_TTL")
    [[ -n "${KERNEL_GIT_CACHE_TTL:-}" ]] && BUILD_CMD+=(KERNEL_GIT_CACHE_TTL="$KERNEL_GIT_CACHE_TTL")
    [[ -n "${GHCR_MIRROR:-}" ]] && BUILD_CMD+=(GHCR_MIRROR="$GHCR_MIRROR")
    [[ -n "${GHCR_MIRROR_ADDRESS:-}" ]] && BUILD_CMD+=(GHCR_MIRROR_ADDRESS="$GHCR_MIRROR_ADDRESS")
    [[ -n "${DOWNLOAD_MIRROR:-}" ]] && BUILD_CMD+=(DOWNLOAD_MIRROR="$DOWNLOAD_MIRROR")
    [[ -n "${REGIONAL_MIRROR:-}" ]] && BUILD_CMD+=(REGIONAL_MIRROR="$REGIONAL_MIRROR")
    [[ -n "${DEBIAN_MIRROR:-}" ]] && BUILD_CMD+=(DEBIAN_MIRROR="$DEBIAN_MIRROR")
    [[ -n "${DEBIAN_SECURITY:-}" ]] && BUILD_CMD+=(DEBIAN_SECURITY="$DEBIAN_SECURITY")
    [[ -n "${UBUNTU_MIRROR:-}" ]] && BUILD_CMD+=(UBUNTU_MIRROR="$UBUNTU_MIRROR")
    [[ -n "${GITHUB_MIRROR:-}" ]] && BUILD_CMD+=(GITHUB_MIRROR="$GITHUB_MIRROR")
    [[ -n "${GHPROXY_ADDRESS:-}" ]] && BUILD_CMD+=(GHPROXY_ADDRESS="$GHPROXY_ADDRESS")
    [[ -n "${GITPROXY_ADDRESS:-}" ]] && BUILD_CMD+=(GITPROXY_ADDRESS="$GITPROXY_ADDRESS")
    # Pass only the directory path. Private key material stays in a mounted
    # protected directory and is never serialized into the build command.
    [[ -n "${UBOOT_FIT_KEYS_BACKUP_DIR:-}" ]] && BUILD_CMD+=(UBOOT_FIT_KEYS_BACKUP_DIR="$UBOOT_FIT_KEYS_BACKUP_DIR")
    [[ -n "${SEEED_RK_EXTENSION_OFFLINE:-}" ]] && BUILD_CMD+=(SEEED_RK_EXTENSION_OFFLINE="$SEEED_RK_EXTENSION_OFFLINE")
    [[ -n "${ARMBIAN_CONFIGNG_OFFLINE:-}" ]] && BUILD_CMD+=(ARMBIAN_CONFIGNG_OFFLINE="$ARMBIAN_CONFIGNG_OFFLINE")
    [[ -n "${ROOTFS_EXTRACT_WITHOUT_PV:-}" ]] && BUILD_CMD+=(ROOTFS_EXTRACT_WITHOUT_PV="$ROOTFS_EXTRACT_WITHOUT_PV")
    [[ -n "${ENABLE_EXTENSIONS:-}" ]] && BUILD_CMD+=(ENABLE_EXTENSIONS="$ENABLE_EXTENSIONS")
    return 0
}

profile_count() {
    local wanted="$1" count=0 profile
    for profile in "${PROFILES[@]}"; do
        [[ "$profile" == "$wanted" ]] && count=$((count + 1))
    done
    echo "$count"
}

profile_is_selected() {
    local wanted="$1" profile
    for profile in "${PROFILES[@]}"; do
        [[ "$profile" == "$wanted" ]] && return 0
    done
    return 1
}

validate_profile_name() {
    case "$1" in
        recovery|ab|secure-rootfs|secure-boot)
            return 0
            ;;
        *)
            die "Unknown profile '$1'. Run '$(basename "$0") --help' for available profiles."
            ;;
    esac
}

# ── Parse arguments ─────────────────────────────────────────────────────────
PROFILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        # Build mode
        --kernel)
            BUILD_KERNEL_ONLY="yes"
            BUILD_DESKTOP="no"
            BUILD_MINIMAL="no"
            shift
            ;;
        --uboot)
            BUILD_UBOOT_ONLY="yes"
            shift
            ;;
        --minimal)
            BUILD_MINIMAL="yes"
            BUILD_DESKTOP="no"
            shift
            ;;
        # Feature toggles
        --no-usbplug)
            RK_COMPILE_USBPLUG="no"
            shift
            ;;
        # Build config
        -b|--board)
            [[ $# -lt 2 ]] && die "Option '$1' requires a value."
            validate_option "board" "$2" "$VALID_BOARDS"
            BOARD="$2"
            shift 2
            ;;
        -R|--release)
            [[ $# -lt 2 ]] && die "Option '$1' requires a value."
            RELEASE="$2"
            shift 2
            ;;
        -d|--desktop)
            [[ $# -lt 2 ]] && die "Option '$1' requires a value."
            validate_option "desktop" "$2" "$VALID_DESKTOPS"
            DESKTOP_ENVIRONMENT="$2"
            shift 2
            ;;
        -t|--tier)
            [[ $# -lt 2 ]] && die "Option '$1' requires a value."
            validate_option "tier" "$2" "$VALID_TIERS"
            DESKTOP_TIER="$2"
            shift 2
            ;;
        --ota-format)
            [[ $# -lt 2 ]] && die "Option '$1' requires a value."
            validate_option "OTA payload format" "$2" "$VALID_OTA_FORMATS"
            OTA_PAYLOAD_COMP="$2"
            shift 2
            ;;
        # Cache and utilities
        -c|--clear-kernel-cache)
            CLEAR_KERNEL_CACHE="yes"
            shift
            ;;
        -r|--clear-rootfs-cache)
            CLEAR_ROOTFS_CACHE="yes"
            shift
            ;;
        -n|--dry-run)
            DRY_RUN="yes"
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            EXTRA_PASSTHROUGH=("$@")
            break
            ;;
        -*)
            die "Unknown option '$1'. Run '$(basename "$0") --help' for usage."
            ;;
        *)
            PROFILES+=("$1")
            shift
            ;;
    esac
done

for profile in "${PROFILES[@]}"; do
    validate_profile_name "$profile"
done

# Resolve build mode conflicts
if [[ "$BUILD_KERNEL_ONLY" == "yes" && "$BUILD_MINIMAL" == "yes" ]]; then
    die "--kernel and --minimal are mutually exclusive."
fi
if [[ "$BUILD_KERNEL_ONLY" == "yes" && "$BUILD_UBOOT_ONLY" == "yes" ]]; then
    die "--kernel and --uboot are mutually exclusive."
fi
if [[ "$BUILD_UBOOT_ONLY" == "yes" && "$BUILD_MINIMAL" == "yes" ]]; then
    die "--uboot and --minimal are mutually exclusive."
fi
if [[ "$BUILD_KERNEL_ONLY" == "yes" && "${#PROFILES[@]}" -gt 0 ]]; then
    warn "--kernel mode ignores profiles '${PROFILES[*]}' (kernel only build)."
    PROFILES=()
fi
if [[ "$BUILD_DESKTOP" != "yes" && ( "$DESKTOP_ENVIRONMENT" != "gnome" || "$DESKTOP_TIER" != "mid" ) ]]; then
    warn "-d/--desktop and -t/--tier have no effect without desktop mode."
fi

for profile in "${PROFILES[@]}"; do
    [[ "$(profile_count "$profile")" -gt 1 ]] && die "Profile '$profile' was specified more than once."
done
if profile_is_selected "recovery" && profile_is_selected "ab"; then
    die "Profiles 'recovery' and 'ab' are mutually exclusive."
fi
if profile_is_selected "secure-boot" && profile_is_selected "secure-rootfs"; then
    die "Profiles 'secure-boot' and 'secure-rootfs' overlap; secure-boot already includes secure-rootfs."
fi

for profile in "${PROFILES[@]}"; do
    if [[ "$BUILD_UBOOT_ONLY" == "yes" ]]; then
        case "$profile" in
            recovery|ab)
                warn "--uboot mode ignores OTA profile '$profile'."
                continue
                ;;
        esac
    fi
    apply_profile "$profile"
done

# Clear uppercase proxy vars to prevent chroot apt/wget from using proxy (avoids SSL 502).
# Lowercase http_proxy/https_proxy from ~/.bashrc are inherited by Docker.
unset HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

# ── Pre-flight checks ───────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
[[ -f compile.sh ]] || die "compile.sh not found in $SCRIPT_DIR"

# ── Cache management ────────────────────────────────────────────────────────
if [[ "$CLEAR_KERNEL_CACHE" == "yes" ]]; then
    echo "Clearing kernel cache..."
    rm -f output/debs/linux-*-vendor-*.deb
    rm -f output/packages-hashed/kernel-*-vendor-*.tar 2>/dev/null
    sudo rm -rf cache/sources/linux-kernel-worktree 2>/dev/null
    echo "Kernel cache cleared."
fi

if [[ "$CLEAR_ROOTFS_CACHE" == "yes" ]]; then
    echo "Clearing rootfs cache..."
    rm -f cache/rootfs/rootfs-arm64-*.tar.zst
    echo "Rootfs cache cleared."
fi

# RK_COMPILE_USBPLUG requires uboot_custom_postprocess to actually run, but
# U-Boot is an Armbian artifact: cache hit skips postprocess entirely, so
# usbplug/spi_nor.img would not be regenerated.
if [[ "$RK_COMPILE_USBPLUG" == "yes" ]]; then
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "[DRY RUN] RK_COMPILE_USBPLUG would clear the matching U-Boot artifact cache."
    else
        echo "RK_COMPILE_USBPLUG requires postprocess; forcing U-Boot cache clear."
        clear_uboot_cache
    fi
fi

# ── Print summary ───────────────────────────────────────────────────────────
echo "==========================================="
if [[ "$BUILD_KERNEL_ONLY" == "yes" ]]; then
    echo " Mode           : kernel only"
elif [[ "$BUILD_UBOOT_ONLY" == "yes" ]]; then
    echo " Mode           : u-boot only"
elif [[ "$BUILD_MINIMAL" == "yes" ]]; then
    echo " Mode           : minimal (no desktop)"
else
    echo " Mode           : desktop"
fi
echo " Board          : $BOARD"
echo " Release        : $RELEASE"
if [[ "$BUILD_DESKTOP" == "yes" && "$BUILD_KERNEL_ONLY" != "yes" && "$BUILD_UBOOT_ONLY" != "yes" ]]; then
    echo " Desktop        : $DESKTOP_ENVIRONMENT ($DESKTOP_TIER)"
fi
if [[ -n "$OTA_ENABLE" || "$SECURITY_PROFILE" != "none" ]]; then
    if [[ "$BUILD_KERNEL_ONLY" != "yes" && "$BUILD_UBOOT_ONLY" != "yes" ]]; then
        echo " OTA            : ${OTA_ENABLE:-board default}"
        echo " A/B OTA        : $AB_PART_OTA"
    fi
    if [[ "$SECURITY_PROFILE" != "none" ]]; then
        echo " Security       : $SECURITY_PROFILE"
        echo " Encryption     : yes"
        echo " Auto-decrypt   : yes"
        [[ "$SECURITY_PROFILE" == "secure-boot" ]] && echo " Secure Boot    : yes" || echo " Secure Boot    : no"
        echo " OP-TEE chain   : yes"
    fi
fi
if [[ "$RK_COMPILE_USBPLUG" == "yes" ]]; then
    echo " USBPLUG        : compiled from source (Maskrom recovery)"
else
    echo " USBPLUG        : rkbin blob (--no-usbplug)"
fi
[[ ${#EXTRA_PASSTHROUGH[@]} -gt 0 ]] && echo " Extra args     : ${EXTRA_PASSTHROUGH[*]}"
echo "==========================================="

# ── Construct build args ────────────────────────────────────────────────────
if [[ "$BUILD_KERNEL_ONLY" == "yes" ]]; then
    BUILD_CMD=(./compile.sh kernel)
    BUILD_CMD+=(
        BOARD="$BOARD"
        BRANCH="$BRANCH"
        RELEASE="$RELEASE"
        KERNEL_CONFIGURE="$KERNEL_CONFIGURE"
        ENABLE_SEEED_RK_EXTENSION="$ENABLE_SEEED_RK_EXTENSION"
    )
elif [[ "$BUILD_UBOOT_ONLY" == "yes" ]]; then
    BUILD_CMD=(./compile.sh uboot)
    BUILD_CMD+=(
        BOARD="$BOARD"
        BRANCH="$BRANCH"
        RELEASE="$RELEASE"
        ENABLE_SEEED_RK_EXTENSION="$ENABLE_SEEED_RK_EXTENSION"
        KERNEL_CONFIGURE="$KERNEL_CONFIGURE"
    )
    append_security_args no
    [[ "$RK_COMPILE_USBPLUG" == "yes" ]] && BUILD_CMD+=(RK_COMPILE_USBPLUG=yes)
else
    BUILD_CMD=(./compile.sh)
    BUILD_CMD+=(
        BOARD="$BOARD"
        BRANCH="$BRANCH"
        RELEASE="$RELEASE"
        BUILD_MINIMAL="$BUILD_MINIMAL"
        BUILD_DESKTOP="$BUILD_DESKTOP"
        KERNEL_CONFIGURE="$KERNEL_CONFIGURE"
        ENABLE_SEEED_RK_EXTENSION="$ENABLE_SEEED_RK_EXTENSION"
    )

    if [[ "$BUILD_DESKTOP" == "yes" ]]; then
        BUILD_CMD+=(
            DESKTOP_ENVIRONMENT="$DESKTOP_ENVIRONMENT"
            DESKTOP_TIER="$DESKTOP_TIER"
        )
    fi

    [[ -n "$OTA_ENABLE" ]] && BUILD_CMD+=(OTA_ENABLE="$OTA_ENABLE")
    [[ -n "$OTA_PAYLOAD_COMP" ]] && BUILD_CMD+=(OTA_PAYLOAD_COMP="$OTA_PAYLOAD_COMP")
    [[ "$AB_PART_OTA" == "yes" ]] && BUILD_CMD+=(AB_PART_OTA=yes)
    append_security_args yes
    [[ "$RK_COMPILE_USBPLUG" == "yes" ]] && BUILD_CMD+=(RK_COMPILE_USBPLUG=yes)
fi

append_cache_ttl_args

# Everything after `--` is passed verbatim to compile.sh: userpatches config
# names (e.g. "industrial-local") and/or KEY=VALUE overrides (e.g. "OTA_ENABLE=no").
BUILD_CMD+=("${EXTRA_PASSTHROUGH[@]}")

# ── Execute or dry-run ──────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "yes" ]]; then
    echo "[DRY RUN] ${BUILD_CMD[*]}"
    exit 0
fi

if [[ "$BUILD_KERNEL_ONLY" != "yes" &&
      "$BUILD_UBOOT_ONLY" != "yes" &&
      "$SECURITY_PROFILE" != "none" &&
      -e /dev/mapper/armbian-root ]]; then
    echo "Closing stale LUKS mapper: armbian-root"
    sudo cryptsetup luksClose armbian-root ||
        die "Unable to close stale LUKS mapper: armbian-root"
fi

"${BUILD_CMD[@]}"
