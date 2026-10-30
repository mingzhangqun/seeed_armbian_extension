#
# Image Naming Helpers
#

function ota_image_layout_suffix() {
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        echo "_AB_PART"
    else
        echo ""
    fi
}

function ota_get_package_type_label() {
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        echo "AB_PART_OTA"
    else
        echo "OTA"
    fi
}

function ota_get_manifest_mode() {
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        echo "ab"
    else
        echo "recovery"
    fi
}

function ota_image_kernel_version_without_family() {
    local kernel_version="$1"

    if [[ -n "${LINUXFAMILY:-}" ]]; then
        kernel_version="${kernel_version/-$LINUXFAMILY/}"
    fi

    echo "${kernel_version}"
}

function ota_image_feature_suffix() {
    echo "${EXTRA_IMAGE_SUFFIX:-}"
}

function ota_image_base_name_from_kernel() {
    local kernel_version_for_image="$1"
    local vendor_version_prelude="${VENDOR}_${IMAGE_VERSION:-"${REVISION}"}_"
    if [[ "${include_vendor_version:-"yes"}" == "no" ]]; then
        vendor_version_prelude=""
    fi

    local base_image_name="${vendor_version_prelude}${BOARD^}_${RELEASE}_${BRANCH}_${kernel_version_for_image}"

    if [[ -n "$DESKTOP_ENVIRONMENT" ]]; then
        base_image_name="${base_image_name}_${DESKTOP_ENVIRONMENT}"
    fi

    local feature_suffix
    feature_suffix="$(ota_image_feature_suffix)"
    if [[ -n "${feature_suffix}" ]]; then
        base_image_name="${base_image_name}${feature_suffix}"
    fi

    if [[ "$BUILD_DESKTOP" == "yes" ]]; then
        base_image_name="${base_image_name}_desktop"
    fi
    if [[ "$BUILD_MINIMAL" == "yes" ]]; then
        base_image_name="${base_image_name}_minimal"
    fi
    if [[ "$ROOTFS_TYPE" == "nfs" ]]; then
        base_image_name="${base_image_name}_nfsboot"
    fi

    local ota_suffix
    ota_suffix="$(ota_image_layout_suffix)"
    if [[ -n "${ota_suffix}" ]]; then
        base_image_name="${base_image_name}${ota_suffix}"
    fi

    echo "${base_image_name}"
}

function ota_image_package_base_name() {
    local kernel_version_for_image="unknown"
    if [[ -n "$KERNEL_VERSION" ]]; then
        kernel_version_for_image="$KERNEL_VERSION"
    elif [[ -n "$IMAGE_INSTALLED_KERNEL_VERSION" ]]; then
        kernel_version_for_image="$(ota_image_kernel_version_without_family "${IMAGE_INSTALLED_KERNEL_VERSION}")"
    fi

    ota_image_base_name_from_kernel "${kernel_version_for_image}"
}

function ota_image_ota_package_name() {
    local base_image_name="$1"
    # Outer shell always compresses with the payload codec (package-create.sh).
    local suffix="tar.gz"
    case "${OTA_PAYLOAD_COMP:-gz}" in
        xz)   suffix="tar.xz" ;;
        zstd) suffix="tar.zst" ;;
    esac
    echo "${base_image_name}_OTA.${suffix}"
}

function ota_image_checksum_name() {
    local base_image_name="$1"
    echo "${base_image_name}_OTA.checksums"
}

function calculate_image_version() {
    declare kernel_version_for_image="unknown"
    kernel_version_for_image="$(ota_image_kernel_version_without_family "${IMAGE_INSTALLED_KERNEL_VERSION}")"

    calculated_image_version="$(ota_image_base_name_from_kernel "${kernel_version_for_image}")"
    display_alert "Calculated image version" "${calculated_image_version}" "debug"
}

