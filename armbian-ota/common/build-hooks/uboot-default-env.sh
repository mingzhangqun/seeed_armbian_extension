# U-Boot default-environment build helpers, shared by A/B and Recovery OTA.
# Sourced unconditionally from seeed_armbian_extension.sh: the packaging hook
# below must also fire during standalone `compile.sh uboot` runs (CI) that carry
# no OTA_* variables, or the published u-boot deb lacks u-boot-default.env and
# image-time env prefill cannot work.

function ota_ab_merge_uboot_env_files() {
    local output_env="$1"
    shift

    awk '
        /^[[:space:]]*#/ || !index($0, "=") {
            next
        }
        {
            key = substr($0, 1, index($0, "=") - 1)
            value = substr($0, index($0, "=") + 1)
            if (!(key in present)) {
                order[++count] = key
                present[key] = 1
            }
            values[key] = value
        }
        END {
            for (position = 1; position <= count; position++) {
                key = order[position]
                print key "=" values[key]
            }
        }
    ' "$@" > "${output_env}"
}

function ota_ab_extract_uboot_default_env() {
    local uboot_elf="$1"
    local output_env="$2"
    local symbol_address rodata_address rodata_offset start_offset

    [[ -f "${uboot_elf}" ]] || return 1

    symbol_address="$(nm -S --defined-only "${uboot_elf}" |
        awk '$NF == "default_environment" { print "0x" $1; exit }')" || return 1
    read -r rodata_address rodata_offset < <(
        readelf -WS "${uboot_elf}" |
            awk '$3 == ".rodata" { print "0x" $5, "0x" $6; exit }'
    )

    [[ -n "${symbol_address}" && -n "${rodata_address}" && -n "${rodata_offset}" ]] || return 1
    start_offset=$((rodata_offset + symbol_address - rodata_address))
    (( start_offset >= 0 )) || return 1

    dd if="${uboot_elf}" bs=1 skip="${start_offset}" status=none |
        tr '\0' '\n' |
        awk 'NF { print; next } { exit }' > "${output_env}"

    grep -q '^distro_bootcmd=' "${output_env}" &&
        grep -q '^scan_dev_for_boot=' "${output_env}" &&
        grep -q '^bootcmd=' "${output_env}"
}

function ota_ab_default_env_file_for_rootfs() {
    local root_dir="$1"
    local candidate
    local -a candidates=("${root_dir}"/usr/lib/linux-u-boot-*/u-boot-default.env)

    for candidate in "${candidates[@]}"; do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

function ota_ab_write_complete_initial_env() {
    local root_dir="$1"
    local default_env merged_env

    default_env="$(ota_ab_default_env_file_for_rootfs "${root_dir}")" || {
        display_alert "A/B U-Boot environment" "Packaged U-Boot default environment not found" "err"
        return 1
    }

    merged_env="$(mktemp)" || return 1
    ota_ab_merge_uboot_env_files "${merged_env}" \
        "${default_env}" \
        "${OTA_AB_ROOTFS}/etc/u-boot-initial-env" || {
        rm -f "${merged_env}"
        return 1
    }

    grep -q '^distro_bootcmd=' "${merged_env}" &&
        grep -q '^scan_dev_for_boot=' "${merged_env}" &&
        grep -q '^scan_dev_for_boot_part=' "${merged_env}" || {
        rm -f "${merged_env}"
        return 1
    }

    install -D -m 0644 "${merged_env}" "${root_dir}/etc/u-boot-initial-env" || {
        rm -f "${merged_env}"
        return 1
    }
    rm -f "${merged_env}"
}

function post_uboot_custom_postprocess__890_package_uboot_default_env() {
    local output_env="${uboottempdir}/usr/lib/${uboot_name}/u-boot-default.env"

    ota_ab_extract_uboot_default_env "$(pwd)/u-boot" "${output_env}" || {
        display_alert "U-Boot environment" "Failed to extract default environment from U-Boot" "err"
        return 1
    }

    display_alert "U-Boot environment" "Packaged compiled default environment" "info"
}

# Sanitize blobs for fw_env_repair_blob, from the compiled default env.
OTA_UBOOT_ENV_SANITIZE_REQUIRED_KEYS=("ota_rescue_boot_fit" "ota_rescue_boot" "bootcmd")

function ota_build_env_sanitize_blobs() {
    local root_dir="$1" default_env mkenvimage_bin env_text key line
    local bin_r bin_s

    default_env="$(ota_ab_default_env_file_for_rootfs "${root_dir}")" || {
        display_alert "OTA sanitize blobs" "U-Boot default env not found in rootfs" "err"
        return 1
    }
    mkenvimage_bin="$(ota_uboot_env_prefill_mkenvimage)" || {
        display_alert "OTA sanitize blobs" "mkenvimage not found" "err"
        return 1
    }

    env_text="$(mktemp)" || return 1
    bin_r="${root_dir}/usr/share/armbian-ota/env-sanitize-redundant.bin"
    bin_s="${root_dir}/usr/share/armbian-ota/env-sanitize-single.bin"

    line="$(grep -m1 '^ota_rescue_boot_fs=' "${default_env}")" &&
        printf '%s\n' "${line}" >> "${env_text}"
    for key in "${OTA_UBOOT_ENV_SANITIZE_REQUIRED_KEYS[@]}"; do
        line="$(grep -m1 "^${key}=" "${default_env}")" || {
            display_alert "OTA sanitize blobs" "key ${key} missing from $(basename "${default_env}")" "err"
            rm -f "${env_text}"
            return 1
        }
        printf '%s\n' "${line}" >> "${env_text}"
    done

    mkdir -p "${root_dir}/usr/share/armbian-ota"
    "${mkenvimage_bin}" -r -s 0x8000 -o "${bin_r}" "${env_text}" || {
        display_alert "OTA sanitize blobs" "mkenvimage -r failed" "err"
        rm -f "${env_text}"
        return 1
    }
    "${mkenvimage_bin}" -s 0x8000 -o "${bin_s}" "${env_text}" || {
        display_alert "OTA sanitize blobs" "mkenvimage failed" "err"
        rm -f "${env_text}" "${bin_r}"
        return 1
    }
    rm -f "${env_text}"
    display_alert "OTA sanitize blobs" "generated env-sanitize-{redundant,single}.bin from $(basename "${default_env}")" "info"
}
