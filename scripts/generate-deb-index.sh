#!/bin/bash
#
# generate-deb-index.sh — generate an HTML index page of .deb packages,
# grouped by category.
#
# Usage: ./scripts/generate-deb-index.sh <debs-dir> <output-html> [sdk-manifest]
#
# Environment variables:
#   REPO_URL          — repository root URL (e.g. https://<owner>.github.io/<repo>, derived from GITHUB_REPOSITORY)
#   GITHUB_REPOSITORY — provided by GitHub Actions (owner/repo)
#   GITHUB_RUN_ID     — used for the build link in the page footer
#

set -euo pipefail

DEBS_DIR="${1:?Usage: $0 <debs-dir> <output-html> [sdk-manifest]}"
OUTPUT_HTML="${2:?Usage: $0 <debs-dir> <output-html> [sdk-manifest]}"
SDK_MANIFEST="${3:-}"

if [[ ! -d "$DEBS_DIR" ]]; then
    echo "ERROR: debs directory '$DEBS_DIR' not found" >&2
    exit 1
fi

# ── Load SDK manifest into a set (associative array) ─────────────────────────
# A text file with one filename per line. Debs whose basename appears in this
# set are classified as "Rockchip SDK" regardless of package name — accurate
# than pattern-matching on names like gstreamer1.0-*, libwayland-*, etc.
declare -A sdk_set=()
if [[ -n "$SDK_MANIFEST" && -f "$SDK_MANIFEST" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        sdk_set["$line"]=1
    done < "$SDK_MANIFEST"
    echo "Loaded ${#sdk_set[@]} SDK deb names from manifest"
fi

# ── Resolve repo URL ─────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-}"
if [[ -z "$REPO_URL" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    OWNER="${GITHUB_REPOSITORY%%/*}"
    REPO_NAME="${GITHUB_REPOSITORY#*/}"
    REPO_URL="https://${OWNER}.github.io/${REPO_NAME}"
fi

# ── Classify a deb by package name ───────────────────────────────────────────
# Args: $1 = package name, $2 = filename. Returns category string.
classify() {
    local name="$1" filename="$2"
    # Manifest match wins first — most accurate signal for SDK packages.
    if [[ -n "${sdk_set[$filename]:-}" ]]; then
        echo "Rockchip SDK"
        return
    fi
    case "$name" in
        linux-image-*|linux-headers-*|linux-dtb-*|linux-source-*|linux-libc-dev-*)
            echo "Kernel"
            ;;
        # Armbian convention: linux-u-boot-${BOARD}_* — no extra dash between
        # "linux-u-boot" and the board name. Both boards land in one U-Boot
        # bucket so the page reads as a single category.
        linux-u-boot-recomputer-rk3576-devkit*|\
        linux-u-boot-recomputer-rk3588-devkit*)
            echo "U-Boot"
            ;;
        armbian-ota*|recomputer-*ota*)
            echo "OTA / Recovery"
            ;;
        camera-engine-rkaiq*|camera_engine_rkisp*)
            echo "Camera (rkaiq)"
            ;;
        fcs960k-aic-bluez*|hostapd-morse-tools*|morsectrl-tools*|\
        wpa-supplicant-morse-tools*|morse-fgh100m-dkms*|morse-*)
            echo "Morse Wi-Fi"
            ;;
        realtek-r8125-dkms*)
            echo "Realtek Ethernet"
            ;;
        usbdevice-gadget*|rk35xx-usb-gadget*)
            echo "USB Gadget"
            ;;
        linux-firmware-rk3576*|linux-firmware-rk3588*)
            echo "Rockchip Firmware"
            ;;
        armbian-*|armbian-firmware*)
            echo "Armbian"
            ;;
        *)
            echo "Other"
            ;;
    esac
}

# ── Escape HTML special characters ───────────────────────────────────────────
# Deb metadata (descriptions, versions) can contain &, <, >, " — escape before
# injecting into the page so it renders correctly instead of being parsed as
# markup. & must be first so we don't double-escape the entities we add.
escape_html() {
    # Use sed with \& (literal &) — bash's ${var//pat/repl} treats an
    # unescaped & in repl as the matched text, which would mangle the
    # entities. & must be substituted first so the entities we add aren't
    # re-escaped.
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# ── Resolve pool path for download links ─────────────────────────────────────
# aptly places each deb under pool/main/<prefix>/<pkgname>/<filename>. Build a
# filename→path map from the aptly publish output (public/, produced by
# publish-aptly.sh) so links match the actual layout — including lib* packages
# whose pool prefix is "lib<2nd-char>" rather than the first char. Falls back
# to the Debian convention when public/ isn't available (e.g. local preview).
declare -A pool_map=()
if [[ -d public ]]; then
    while IFS= read -r f; do
        pool_map["$(basename "$f")"]="${f#public/}"
    done < <(find public/pool -type f -name '*.deb' 2>/dev/null)
fi

pool_path_for() {
    local filename="$1" pkgname="$2"
    if [[ -n "${pool_map[$filename]:-}" ]]; then
        printf '%s' "${pool_map[$filename]}"
        return
    fi
    local prefix
    if [[ "$pkgname" == lib* ]]; then
        prefix="lib${pkgname:3:1}"
    else
        prefix="${pkgname:0:1}"
    fi
    printf 'pool/main/%s/%s/%s' "$prefix" "$pkgname" "$filename"
}

# ── Category order & display ─────────────────────────────────────────────────
CATEGORY_ORDER=(
    "Kernel"
    "U-Boot"
    "Rockchip Firmware"
    "Camera (rkaiq)"
    "Morse Wi-Fi"
    "Realtek Ethernet"
    "USB Gadget"
    "OTA / Recovery"
    "Rockchip SDK"
    "Armbian"
    "Other"
)

# ── Collect debs into per-category lists ─────────────────────────────────────
declare -A entries=()
total=0

while IFS= read -r deb; do
    [[ -z "$deb" ]] && continue
    filename=$(basename "$deb")
    # Extract metadata (Package, Version, Architecture, Description, Installed-Size)
    metadata=$(dpkg-deb -f "$deb")
    # Authoritative package name from the control file — more reliable than
    # stripping _<version>_<arch>.deb off the filename (which mis-parses when
    # a package name itself contains _<digit>).
    pkgname=$(printf '%s' "$metadata" | awk '/^Package:/{sub(/^Package: /,""); print; exit}')
    category=$(classify "$pkgname" "$filename")
    version=$(printf '%s' "$metadata" | awk '/^Version:/{sub(/^Version: /,""); print; exit}')
    arch=$(printf '%s' "$metadata" | awk '/^Architecture:/{sub(/^Architecture: /,""); print; exit}')
    description=$(printf '%s' "$metadata" | awk '/^Description:/{sub(/^Description: /,""); print; exit}')
    inst_size=$(printf '%s' "$metadata" | awk '/^Installed-Size:/{print $2; exit}')
    file_size=$(stat -c%s "$deb")

    # Human-readable sizes
    file_size_h=$(numfmt --to=iec --suffix=B "$file_size" 2>/dev/null || printf '%s bytes' "$file_size")
    inst_size_h=""
    if [[ -n "$inst_size" ]]; then
        inst_size_h=$(numfmt --to=iec --suffix=B "$((inst_size * 1024))" 2>/dev/null || printf '%s KB' "$inst_size")
    fi

    entries[$category]+="${filename}"$'\t'"${pkgname}"$'\t'"${version}"$'\t'"${arch}"$'\t'"${description}"$'\t'"${file_size_h}"$'\t'"${inst_size_h}"$'\n'
    total=$((total + 1))
done < <(find "$DEBS_DIR" -name '*.deb' -type f | sort)

# ── Compute build timestamp ──────────────────────────────────────────────────
BUILD_DATE=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# ── Generate HTML ────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT_HTML")"

{
    printf '<!DOCTYPE html>\n'
    printf '<html lang="en">\n<head>\n'
    printf '<meta charset="UTF-8">\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
    printf '<title>Seeed reComputer APT Repository</title>\n'
    printf '<style>\n'
    cat <<'EOF'
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
       max-width: 1200px; margin: 0 auto; padding: 20px; color: #24292e; line-height: 1.5; }
h1 { color: #1f2328; border-bottom: 2px solid #0969da; padding-bottom: 10px; }
h2 { color: #1f2328; margin-top: 36px; padding-bottom: 6px; border-bottom: 1px solid #d0d7de; }
h2 .count { color: #656d76; font-weight: normal; font-size: 0.85em; }
table { border-collapse: collapse; width: 100%; margin: 8px 0 24px; font-size: 14px; }
th, td { border: 1px solid #d0d7de; padding: 6px 10px; text-align: left; vertical-align: top; }
th { background-color: #f6f8fa; font-weight: 600; }
tr:nth-child(even) { background-color: #f9fafb; }
td.pkg code { background: #ddf4ff; color: #0969da; padding: 1px 5px; border-radius: 4px;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
td.file, td.arch, td.size { white-space: nowrap; color: #656d76; }
td.desc { color: #656d76; max-width: 400px; }
code.inline { background: #f6f8fa; padding: 2px 6px; border-radius: 4px;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
pre { background: #f6f8fa; padding: 14px; border-radius: 6px; overflow-x: auto;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px;
      border: 1px solid #d0d7de; }
header.usage { background: #f6f8fa; padding: 16px 20px; border-radius: 8px; border: 1px solid #d0d7de; }
.summary { display: flex; gap: 24px; margin: 12px 0 24px; flex-wrap: wrap; }
.summary div { background: #f6f8fa; padding: 10px 16px; border-radius: 6px; border: 1px solid #d0d7de; }
.summary strong { color: #0969da; font-size: 18px; }
footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid #d0d7de;
         color: #656d76; font-size: 13px; }
footer a { color: #0969da; text-decoration: none; }
td.pkg a { color: #0969da; text-decoration: none; }
td.pkg a:hover { text-decoration: underline; }
EOF
    printf '</style>\n</head>\n<body>\n'
    printf '<h1>Seeed reComputer APT Repository</h1>\n'

    # ── Usage block ──────────────────────────────────────────────────────────
    if [[ -n "$REPO_URL" ]]; then
        printf '<header class="usage">\n'
        printf '<h2 style="margin-top:0;">Usage</h2>\n'
        printf '<pre>\n'
        printf '# Import GPG key\n'
        printf 'curl -fsSL %s/seeed-repo.gpg \\\n' "$REPO_URL"
        printf '  | sudo gpg --dearmor -o /usr/share/keyrings/seeed-repo.gpg\n\n'
        printf '# Add repository\n'
        printf 'echo "deb [signed-by=/usr/share/keyrings/seeed-repo.gpg] %s/ stable main" \\\n' "$REPO_URL"
        printf '  | sudo tee /etc/apt/sources.list.d/seeed.list\n\n'
        printf '# Install packages\n'
        printf 'sudo apt update\n'
        printf 'sudo apt install &lt;package-name&gt;\n'
        printf '</pre>\n'
        printf '</header>\n'
    fi

    # ── Summary stats ────────────────────────────────────────────────────────
    printf '<div class="summary">\n'
    printf '<div>Total packages: <strong>%d</strong></div>\n' "$total"
    printf '<div>Categories: <strong>%d</strong></div>\n' \
        "$(for c in "${CATEGORY_ORDER[@]}"; do [[ -n "${entries[$c]:-}" ]] && echo "$c"; done | wc -l)"
    printf '<div>Updated: <strong>%s</strong></div>\n' "$BUILD_DATE"
    printf '</div>\n'

    # ── Per-category tables ──────────────────────────────────────────────────
    for category in "${CATEGORY_ORDER[@]}"; do
        [[ -z "${entries[$category]:-}" ]] && continue

        count=$(printf '%s' "${entries[$category]}" | grep -c . || true)
        printf '<h2>%s <span class="count">(%d)</span></h2>\n' "$category" "$count"
        printf '<table>\n'
        printf '<tr><th>Package</th><th>Version</th><th>Arch</th><th>File</th><th>Installed</th><th>Description</th></tr>\n'

        while IFS=$'\t' read -r filename pkgname version arch description file_size_h inst_size_h; do
            [[ -z "$filename" ]] && continue
            pool_path=$(pool_path_for "$filename" "$pkgname")
            href="${REPO_URL:+${REPO_URL}/}${pool_path}"
            printf '<tr>'
            printf '<td class="pkg"><a href="%s" download><code>%s</code></a></td>' "$(escape_html "$href")" "$(escape_html "$pkgname")"
            printf '<td>%s</td>' "$(escape_html "$version")"
            printf '<td class="arch">%s</td>' "$(escape_html "$arch")"
            printf '<td class="file">%s</td>' "$(escape_html "$file_size_h")"
            printf '<td class="size">%s</td>' "$(escape_html "${inst_size_h:-—}")"
            printf '<td class="desc">%s</td>' "$(escape_html "$description")"
            printf '</tr>\n'
        done <<< "${entries[$category]}"

        printf '</table>\n'
    done

    # ── Footer ───────────────────────────────────────────────────────────────
    printf '<footer>\n'
    printf 'Generated by <code class="inline">scripts/generate-deb-index.sh</code> '
    printf 'from seeed_armbian_extension CI.<br>\n'
    if [[ -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
        printf 'Build: <a href="https://github.com/%s/actions/runs/%s">%s</a> ' \
            "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$GITHUB_RUN_ID"
        printf 'at %s\n' "$BUILD_DATE"
    else
        printf 'Generated at %s\n' "$BUILD_DATE"
    fi
    printf '</footer>\n'
    printf '</body>\n</html>\n'
} > "$OUTPUT_HTML"

echo "Generated: $OUTPUT_HTML"
echo "  Total packages: $total"
echo "  Categories:"
for category in "${CATEGORY_ORDER[@]}"; do
    [[ -z "${entries[$category]:-}" ]] && continue
    count=$(printf '%s' "${entries[$category]}" | grep -c . || true)
    printf '    %-25s %d\n' "$category:" "$count"
done
