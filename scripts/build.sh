#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
BOARD="recomputer-rk3576-devkit"
BRANCH="vendor"
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
BUILD_MINIMAL="no"
BUILD_DESKTOP="yes"

# Feature flags (all off by default; profiles enable what they need)
OTA_ENABLE="no"
AB_PART_OTA="no"
CRYPTROOT_ENABLE="no"
RK_AUTO_DECRYP="no"
RK_SECURE_UBOOT_ENABLE="no"
RK_OPTEE_BOOT_ENABLE="no"

CRYPTROOT_PASSPHRASE="${CRYPTROOT_PASSPHRASE:-}"

# Valid option values
VALID_BOARDS="recomputer-rk3576-devkit recomputer-rk3588-devkit"
VALID_DESKTOPS="gnome xfce kde-plasma mate cinnamon"
VALID_TIERS="minimal mid full"

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [profile] [options]

Profiles (feature sets, default: plain desktop build):
  recovery-ota  Recovery OTA + encryption + auto-decrypt
  ab-ota        A/B dual-partition OTA + encryption + auto-decrypt
  secure-boot   Secure U-Boot + encryption + auto-decrypt
  optee         OP-TEE boot + encryption + auto-decrypt
  max           All features: A/B OTA + encryption + secure boot + OP-TEE

Options:
  Build mode:
  --kernel                    Build kernel only (skip u-boot, rootfs, image)
  --minimal                   Build minimal system (no desktop)

  Build config:
  -b, --board BOARD           Board name (default: recomputer-rk3576-devkit)
                              Options: recomputer-rk3576-devkit, recomputer-rk3588-devkit
  -R, --release RELEASE       Release/distro (default: bookworm)
                              Debian:  trixie, bookworm, bullseye, buster, sid, forky, resolute
                              Ubuntu:  plucky, oracular, noble, jammy, focal, questing
  -d, --desktop DE            Desktop environment (default: gnome)
                              Options: gnome, xfce, kde-plasma, mate, cinnamon
  -t, --tier TIER             Desktop tier (default: mid)
                              Options: minimal, mid, full

  Utilities:
  -k, --kernel-config         Interactive kernel config
  -c, --clear-kernel-cache    Clear kernel deb/worktree cache before build
  -r, --clear-rootfs-cache    Clear rootfs cache before build
  -n, --dry-run               Show build config without running compile.sh
  -h, --help                  Show this help

Examples:
  $(basename "$0")                              # Default: GNOME desktop, bookworm
  $(basename "$0") -d xfce -R noble             # XFCE on Ubuntu noble
  $(basename "$0") --minimal                    # No desktop, minimal system
  $(basename "$0") --kernel -c                  # Kernel only, clear cache
  $(basename "$0") recovery-ota                 # Recovery OTA + encryption
  $(basename "$0") max -d xfce                  # All features with XFCE
  $(basename "$0") ab-ota -b recomputer-rk3588-devkit
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

# ── Profile application ─────────────────────────────────────────────────────
apply_profile() {
    local profile="${1:-}"
    [[ -z "$profile" ]] && return 0
    case "$profile" in
        recovery-ota)
            OTA_ENABLE="yes"
            AB_PART_OTA="no"
            CRYPTROOT_ENABLE="yes"
            RK_AUTO_DECRYP="yes"
            ;;
        ab-ota)
            OTA_ENABLE="yes"
            AB_PART_OTA="yes"
            CRYPTROOT_ENABLE="yes"
            RK_AUTO_DECRYP="yes"
            ;;
        secure-boot)
            OTA_ENABLE="yes"
            CRYPTROOT_ENABLE="yes"
            RK_AUTO_DECRYP="yes"
            RK_SECURE_UBOOT_ENABLE="yes"
            ;;
        optee)
            OTA_ENABLE="yes"
            CRYPTROOT_ENABLE="yes"
            RK_AUTO_DECRYP="yes"
            RK_OPTEE_BOOT_ENABLE="yes"
            ;;
        max)
            OTA_ENABLE="yes"
            AB_PART_OTA="yes"
            CRYPTROOT_ENABLE="yes"
            RK_AUTO_DECRYP="yes"
            RK_SECURE_UBOOT_ENABLE="yes"
            RK_OPTEE_BOOT_ENABLE="yes"
            ;;
        *)
            die "Unknown profile '$profile'. Run '$(basename "$0") --help' for available profiles."
            ;;
    esac
}

# ── Parse arguments ─────────────────────────────────────────────────────────
PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel)
            BUILD_KERNEL_ONLY="yes"
            BUILD_DESKTOP="no"
            BUILD_MINIMAL="no"
            shift
            ;;
        --minimal)
            BUILD_MINIMAL="yes"
            BUILD_DESKTOP="no"
            shift
            ;;
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
        -k|--kernel-config)
            KERNEL_CONFIGURE="yes"
            shift
            ;;
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
        -*)
            die "Unknown option '$1'. Run '$(basename "$0") --help' for usage."
            ;;
        *)
            if [[ -n "$PROFILE" ]]; then
                die "Multiple profiles specified: '$PROFILE' and '$1'. Only one profile is allowed."
            fi
            PROFILE="$1"
            shift
            ;;
    esac
done

# Resolve build mode conflicts
if [[ "$BUILD_KERNEL_ONLY" == "yes" && "$BUILD_MINIMAL" == "yes" ]]; then
    die "--kernel and --minimal are mutually exclusive."
fi
if [[ "$BUILD_KERNEL_ONLY" == "yes" && -n "$PROFILE" ]]; then
    warn "--kernel mode ignores profile '$PROFILE' (kernel only build)."
    PROFILE=""
fi
if [[ "$BUILD_DESKTOP" != "yes" && ( "$DESKTOP_ENVIRONMENT" != "gnome" || "$DESKTOP_TIER" != "mid" ) ]]; then
    warn "-d/--desktop and -t/--tier have no effect without desktop mode."
fi

apply_profile "$PROFILE"

# Clear uppercase proxy vars to prevent chroot apt/wget from using proxy (avoids SSL 502).
# Lowercase http_proxy/https_proxy from ~/.bashrc are inherited by Docker.
unset HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

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

# ── Pre-flight checks ───────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
[[ -f compile.sh ]] || die "compile.sh not found in $SCRIPT_DIR"

# ── Print summary ───────────────────────────────────────────────────────────
echo "==========================================="
if [[ "$BUILD_KERNEL_ONLY" == "yes" ]]; then
    echo " Mode           : kernel only"
elif [[ "$BUILD_MINIMAL" == "yes" ]]; then
    echo " Mode           : minimal (no desktop)"
else
    echo " Mode           : desktop"
fi
echo " Board          : $BOARD"
echo " Release        : $RELEASE"
if [[ "$BUILD_DESKTOP" == "yes" ]]; then
    echo " Desktop        : $DESKTOP_ENVIRONMENT ($DESKTOP_TIER)"
fi
if [[ "$OTA_ENABLE" == "yes" || "$CRYPTROOT_ENABLE" == "yes" ]]; then
    echo " OTA            : $OTA_ENABLE"
    echo " A/B OTA        : $AB_PART_OTA"
    echo " Encryption     : $CRYPTROOT_ENABLE"
    echo " Secure Boot    : $RK_SECURE_UBOOT_ENABLE"
    echo " OP-TEE         : $RK_OPTEE_BOOT_ENABLE"
fi
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
        OTA_ENABLE="$OTA_ENABLE"
    )

    if [[ "$BUILD_DESKTOP" == "yes" ]]; then
        BUILD_CMD+=(
            DESKTOP_ENVIRONMENT="$DESKTOP_ENVIRONMENT"
            DESKTOP_TIER="$DESKTOP_TIER"
        )
    fi

    [[ "$AB_PART_OTA" == "yes" ]] && BUILD_CMD+=(AB_PART_OTA=yes)
    [[ "$CRYPTROOT_ENABLE" == "yes" ]] && {
        [[ -z "$CRYPTROOT_PASSPHRASE" ]] && die "CRYPTROOT_PASSPHRASE is required for encrypted builds. Set it in environment."
        BUILD_CMD+=(CRYPTROOT_ENABLE=yes CRYPTROOT_PASSPHRASE="$CRYPTROOT_PASSPHRASE")
    }
    [[ "$RK_AUTO_DECRYP" == "yes" ]] && BUILD_CMD+=(RK_AUTO_DECRYP=yes)
    [[ "$RK_SECURE_UBOOT_ENABLE" == "yes" ]] && BUILD_CMD+=(RK_SECURE_UBOOT_ENABLE=yes)
    [[ "$RK_OPTEE_BOOT_ENABLE" == "yes" ]] && BUILD_CMD+=(RK_OPTEE_BOOT_ENABLE=yes)
fi

# ── Execute or dry-run ──────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "yes" ]]; then
    echo "[DRY RUN] ${BUILD_CMD[*]}"
    exit 0
fi

"${BUILD_CMD[@]}"
