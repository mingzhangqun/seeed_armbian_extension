#!/bin/bash
#
# publish-aptly.sh — 使用 aptly 构建 apt 仓库并发布到 GitHub Pages
#
# 用法: ./scripts/publish-aptly.sh <noble-debs-dir> [bookworm-debs-dir]
#
# 创建两个 distribution:
#   stable     — Noble (Ubuntu 24.04) 包
#   bookworm   — Debian Bookworm 包
#
# 环境变量:
#   ARMBIAN_APT_GPG_KEY_ID — GPG 签名密钥 ID

set -euo pipefail

NOBLE_DIR="${1:?Usage: $0 <noble-debs-dir> [bookworm-debs-dir]}"
BOOKWORM_DIR="${2:-}"
GPG_KEY="${ARMBIAN_APT_GPG_KEY_ID:?ARMBIAN_APT_GPG_KEY_ID not set}"
PUBLIC_DIR="$(pwd)/public"

APTLY_ROOT="/tmp/aptly-work"
APTLY_CONFIG="${APTLY_ROOT}/aptly.conf"
REPO_DIR="${APTLY_ROOT}/repo"

echo "=== Step 1: Configure aptly ==="
mkdir -p "${APTLY_ROOT}"

cat > "${APTLY_CONFIG}" << EOF
{
  "rootDir": "${APTLY_ROOT}/repo",
  "downloadConcurrency": 4,
  "downloadSpeedLimit": 0,
  "architectures": ["arm64"],
  "dependencyFollowSuggests": false,
  "dependencyFollowRecommends": false,
  "dependencyFollowAllVariants": false,
  "dependencyFollowSource": false,
  "gpgDisableSign": false,
  "gpgDisableVerify": true,
  "gpgProvider": "gpg2",
  "skipContents": false,
  "skipBz2": false,
  "ppaDistributorID": "ubuntu",
  "ppaCodename": ""
}
EOF

mkdir -p "${REPO_DIR}"

# ──────────────────────────────────────────────────
# Noble → stable distribution
# ──────────────────────────────────────────────────
echo ""
echo "=== Step 2: Build Noble (stable) repository ==="
NOBLE_COUNT=$(find "${NOBLE_DIR}" -name '*.deb' | wc -l)
echo "Found ${NOBLE_COUNT} Noble deb packages"
if [[ "${NOBLE_COUNT}" -eq 0 ]]; then
    echo "ERROR: No .deb files found in ${NOBLE_DIR}"
    exit 1
fi
find "${NOBLE_DIR}" -name '*.deb' -exec basename {} \;

REPO_NOBLE="seeed-recomputer-stable"
aptly -config="${APTLY_CONFIG}" \
    repo create \
    -distribution="stable" \
    -component="main" \
    -architectures="arm64" \
    "${REPO_NOBLE}" 2>/dev/null || true

for deb in "${NOBLE_DIR}"/*.deb; do
    echo "  Adding (stable): $(basename "${deb}")"
    aptly -config="${APTLY_CONFIG}" repo add "${REPO_NOBLE}" "${deb}"
done

aptly -config="${APTLY_CONFIG}" repo show "${REPO_NOBLE}"

echo ""
echo "=== Step 3: Publish Noble (stable) ==="
aptly -config="${APTLY_CONFIG}" \
    -batch \
    -gpg-key="${GPG_KEY}" \
    publish repo \
    -distribution="stable" \
    -component="main" \
    -architectures="arm64" \
    -label="Seeed Studio" \
    -origin="Seeed Studio" \
    "${REPO_NOBLE}"

# ──────────────────────────────────────────────────
# Bookworm → bookworm distribution (optional)
# ──────────────────────────────────────────────────
if [[ -n "${BOOKWORM_DIR}" ]] && [[ -d "${BOOKWORM_DIR}" ]]; then
    BOOKWORM_COUNT=$(find "${BOOKWORM_DIR}" -name '*.deb' | wc -l)
    echo ""
    echo "=== Step 4: Build Bookworm repository (${BOOKWORM_COUNT} debs) ==="
    if [[ "${BOOKWORM_COUNT}" -eq 0 ]]; then
        echo "WARNING: No .deb files in ${BOOKWORM_DIR}, skipping Bookworm distribution"
    else
        find "${BOOKWORM_DIR}" -name '*.deb' -exec basename {} \;

        REPO_BW="seeed-recomputer-bookworm"
        aptly -config="${APTLY_CONFIG}" \
            repo create \
            -distribution="bookworm" \
            -component="main" \
            -architectures="arm64" \
            "${REPO_BW}" 2>/dev/null || true

        for deb in "${BOOKWORM_DIR}"/*.deb; do
            echo "  Adding (bookworm): $(basename "${deb}")"
            aptly -config="${APTLY_CONFIG}" repo add "${REPO_BW}" "${deb}"
        done

        aptly -config="${APTLY_CONFIG}" repo show "${REPO_BW}"

        echo ""
        echo "=== Step 5: Publish Bookworm ==="
        # Bookworm repo shares pool/ with stable via aptly's filesystem layout
        aptly -config="${APTLY_CONFIG}" \
            -batch \
            -gpg-key="${GPG_KEY}" \
            publish repo \
            -distribution="bookworm" \
            -component="main" \
            -architectures="arm64" \
            -label="Seeed Studio" \
            -origin="Seeed Studio" \
            "${REPO_BW}"
    fi
else
    echo ""
    echo "=== Step 4: No Bookworm debs provided, skipping ==="
fi

# ──────────────────────────────────────────────────
# Copy published files to public/
# ──────────────────────────────────────────────────
echo ""
echo "=== Step 6: Copy published files to public/ ==="
PUBLISH_DIR="${APTLY_ROOT}/repo/public"
if [[ -d "${PUBLISH_DIR}" ]]; then
    mkdir -p "${PUBLIC_DIR}"
    cp -r "${PUBLISH_DIR}"/* "${PUBLIC_DIR}/"

    # 复制 GPG 公钥
    gpg --export --armor "${GPG_KEY}" > "${PUBLIC_DIR}/seeed-repo.gpg"

    echo "Published structure:"
    find "${PUBLIC_DIR}" -type f | sort
else
    echo "ERROR: Published directory not found at ${PUBLISH_DIR}"
    exit 1
fi

echo ""
echo "=== Done ==="
echo "APT Repository published successfully!"
echo "URL: https://seeed-studio.github.io/seeed_armbian_extension/"
echo ""
echo "Distributions:"
echo "  stable     — Noble (Ubuntu 24.04) packages"
if [[ -d "${PUBLIC_DIR}/dists/bookworm" ]]; then
    echo "  bookworm   — Debian Bookworm packages"
fi
echo ""
echo "To use (Noble):"
echo "  curl -fsSL https://seeed-studio.github.io/seeed_armbian_extension/seeed-repo.gpg | sudo gpg --dearmor -o /usr/share/keyrings/seeed-repo.gpg"
echo '  echo "deb [signed-by=/usr/share/keyrings/seeed-repo.gpg] https://seeed-studio.github.io/seeed_armbian_extension/ stable main" | sudo tee /etc/apt/sources.list.d/seeed.list'
echo "To use (Bookworm):"
echo '  echo "deb [signed-by=/usr/share/keyrings/seeed-repo.gpg] https://seeed-studio.github.io/seeed_armbian_extension/ bookworm main" | sudo tee /etc/apt/sources.list.d/seeed.list'
echo "  sudo apt-get update"
