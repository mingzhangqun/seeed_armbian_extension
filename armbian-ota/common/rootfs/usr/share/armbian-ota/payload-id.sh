#!/bin/bash

# Payload identity, single-sourced for the build side (package-create.sh)
# and the device side (recovery/backend.sh); provenance is in payload.env.

# Deterministic tree hash: every file's sha256 in sorted path order; the
# payload-id file itself is excluded so the ID never hashes its container.
ota_payload_tree_hash() {
    local tree_dir="$1"

    (
        cd "${tree_dir}" || exit 1
        find . -type f ! -name payload-id -print0 | LC_ALL=C sort -z |
            xargs -0 -r sha256sum
    ) | awk '{print $1"  "substr($2,3)}' | sha256sum | awk '{print $1}'
}

ota_compute_payload_id() { # $1 = rootfs tar, $2 = boot staging tree
    local root_sha boot_sha

    root_sha="$(sha256sum "$1" | awk '{print $1}')"
    boot_sha="$(ota_payload_tree_hash "$2")"

    printf 'armbian-ota-payload-v2|R=%s|B=%s|HAS_ROOTFS=1\n' \
        "${root_sha}" "${boot_sha}" |
        sha256sum | awk '{print $1}'
}

# payload.env identity card, single writer for both sides (same sourcing
# contract as the hash above); the field set is what 99-ota-apply and the
# metadata gates consume, so it cannot drift between build and device.
ota_write_payload_env() {
    local dir="$1" id="$2" fmt="$3" board="$4" release="$5" kernel="$6" version="$7"

    {
        echo "PAYLOAD_ID=${id}"
        echo "KIND=full"
        echo "FMT=${fmt}"
        echo "HAS_ROOTFS=1"
        echo "BOARD=${board}"
        echo "RELEASE=${release}"
        echo "KERNEL=${kernel}"
        echo "VERSION=${version}"
        echo "OTA_MODE=recovery"
    } > "${dir}/payload.env"
}
