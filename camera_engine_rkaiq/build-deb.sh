#!/bin/bash
#
# build-deb.sh — Build camera-engine-rkaiq deb for a specific SoC
#
# Usage: ./build-deb.sh <soc>
#   soc: rk3576 or rk3588
#
# Environment:
#   DEB_BUILD_OPTIONS — e.g. "noddebs"
#

set -euo pipefail

SOC="${1:?Usage: $0 <rk3576|rk3588>}"

# Map SoC to ISP version directory
case "${SOC}" in
    rk3576) IQDIR="isp39" ;;
    rk3588) IQDIR="isp3x" ;;
    *) echo "ERROR: Unsupported SoC: ${SOC}. Use rk3576 or rk3588."; exit 1 ;;
esac

# Get version from source
VERSION=$(grep 'RK_AIQ_VERSION_REAL_V' rkaiq/RkAiqVersion.h | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr -d 'v')
DEB_RELEASE="${DEB_RELEASE:-1}"

echo "=== Building camera-engine-rkaiq-${SOC} ==="
echo "SoC: ${SOC}"
echo "ISP dir: ${IQDIR}"
echo "Version: ${VERSION}"

# Generate debian files from templates
echo ""
echo "=== Generating debian files ==="
for template in debian/control.in debian/changelog.in debian/rules.in \
                debian/camera-engine-rkaiq-@SOC@.postinst.in \
                debian/camera-engine-rkaiq-@SOC@.prerm.in; do
    out="${template%.in}"
    out="${out//@SOC@/${SOC}}"
    out="${out//@VERSION@/${VERSION}}"
    out="${out//@IQDIR@/${IQDIR}}"
    sed -e "s/@SOC@/${SOC}/g" \
        -e "s/@VERSION@/${VERSION}/g" \
        -e "s/@IQDIR@/${IQDIR}/g" \
        -e "s/@DEB_RELEASE@/${DEB_RELEASE}/g" \
        "${template}" > "${out}"
    echo "  Generated: ${out}"
done

# Make rules executable
chmod +x debian/rules

# Clean any previous build
rm -rf build/

echo ""
echo "=== Building package ==="
DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-noddebs}" dpkg-buildpackage -us -uc -b

echo ""
echo "=== Done ==="
ls -lh ../camera-engine-rkaiq-${SOC}_*.deb 2>/dev/null || echo "No deb found"
