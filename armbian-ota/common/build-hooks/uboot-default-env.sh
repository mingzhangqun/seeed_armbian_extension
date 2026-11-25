# U-Boot default-environment build helpers, shared by A/B and Recovery OTA.
# Sourced unconditionally: the packaging hook below must also fire during
# standalone `compile.sh uboot` runs (CI) that carry no OTA_* variables, or
# the published u-boot deb lacks u-boot-default.env.

function ota_merge_uboot_env_files() {
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

function ota_extract_uboot_default_env() {
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

function ota_default_env_file_for_rootfs() {
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

function post_uboot_custom_postprocess__890_package_uboot_default_env() {
    local output_env="${uboottempdir}/usr/lib/${uboot_name}/u-boot-default.env"

    ota_extract_uboot_default_env "$(pwd)/u-boot" "${output_env}" || {
        display_alert "U-Boot environment" "Failed to extract default environment from U-Boot" "err"
        return 1
    }

    display_alert "U-Boot environment" "Packaged compiled default environment" "info"
}
