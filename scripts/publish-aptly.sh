#!/bin/bash
#
# publish-aptly.sh — 使用 aptly 构建 apt 仓库并发布到 GitHub Pages
#
# 用法: ./scripts/publish-aptly.sh <debs-dir>
#
# 创建 distribution:
#   stable     — 所有发行版通用（bookworm 构建，向前兼容）
#
# 环境变量:
#   ARMBIAN_APT_GPG_KEY_ID — GPG 签名密钥 ID

set -euo pipefail

DEBS_DIR="${1:?Usage: $0 <debs-dir>}"
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
# Build and publish stable distribution
# ──────────────────────────────────────────────────
echo ""
echo "=== Step 2: Build repository ==="
DEB_COUNT=$(find "${DEBS_DIR}" -name '*.deb' | wc -l)
echo "Found ${DEB_COUNT} deb packages"
if [[ "${DEB_COUNT}" -eq 0 ]]; then
    echo "ERROR: No .deb files found in ${DEBS_DIR}"
    exit 1
fi
find "${DEBS_DIR}" -name '*.deb' -exec basename {} \;

REPO_NAME="seeed-recomputer"
aptly -config="${APTLY_CONFIG}" \
    repo create \
    -distribution="stable" \
    -component="main" \
    -architectures="arm64" \
    "${REPO_NAME}" 2>/dev/null || true

for deb in "${DEBS_DIR}"/*.deb; do
    echo "  Adding: $(basename "${deb}")"
    aptly -config="${APTLY_CONFIG}" repo add "${REPO_NAME}" "${deb}"
done

aptly -config="${APTLY_CONFIG}" repo show "${REPO_NAME}"

echo ""
echo "=== Step 3: Publish stable ==="
aptly -config="${APTLY_CONFIG}" \
    -batch \
    -gpg-key="${GPG_KEY}" \
    publish repo \
    -distribution="stable" \
    -component="main" \
    -architectures="arm64" \
    -label="Seeed Studio" \
    -origin="Seeed Studio" \
    "${REPO_NAME}"

# ──────────────────────────────────────────────────
# Copy published files to public/
# ──────────────────────────────────────────────────
echo ""
echo "=== Step 4: Copy published files to public/ ==="
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

# Compute Pages URL from GITHUB_REPOSITORY (works for forks). Falls back to the
# upstream Seeed-Studio URL when running outside CI.
if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    OWNER="${GITHUB_REPOSITORY%%/*}"
    REPO_NAME="${GITHUB_REPOSITORY#*/}"
    PAGES_URL="https://${OWNER}.github.io/${REPO_NAME}/"
else
    PAGES_URL="https://seeed-studio.github.io/seeed_armbian_extension/"
fi
echo "URL: ${PAGES_URL}"
echo ""
echo "Distribution: stable (all releases)"
echo ""
echo "To use:"
echo "  curl -fsSL ${PAGES_URL}seeed-repo.gpg | sudo gpg --dearmor -o /usr/share/keyrings/seeed-repo.gpg"
echo '  echo "deb [signed-by=/usr/share/keyrings/seeed-repo.gpg] '"${PAGES_URL}"' stable main" | sudo tee /etc/apt/sources.list.d/seeed.list'
echo "  sudo apt-get update"
