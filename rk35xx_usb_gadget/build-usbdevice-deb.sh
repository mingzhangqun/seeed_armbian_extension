#!/usr/bin/env bash
set -euo pipefail
PKGROOT="$(cd "$(dirname "$0")" && pwd)/usbdevice-gadget-deb"
OUTDIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(awk -F': ' '/^Version:/{print $2}' "$PKGROOT/DEBIAN/control")
ARCH=$(awk -F': ' '/^Architecture:/{print $2}' "$PKGROOT/DEBIAN/control")
OUT="$OUTDIR/usbdevice-gadget-rk_${VERSION}_${ARCH}.deb"
dpkg-deb -b "$PKGROOT" "$OUT"
echo "$OUT"
