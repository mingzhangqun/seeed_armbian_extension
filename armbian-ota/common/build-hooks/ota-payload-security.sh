# OTA payload encryption + signing.

# Encrypted rootfs still ships a plaintext payload tar (leaks the rootfs
# over the distribution channel): encrypt it (AES-256-CBC, HKDF key from
# the LUKS passphrase) and sign the manifest with the secure-boot RSA key.
# Decryption + verification run on-device (ab_start_ota /
# recovery_start_ota); the initramfs extracts only the decrypted tar.

# Payload encryption mirrors the on-device auto-decrypt capability: only when
# the device can retrieve the passphrase unattended (security partition /
# OP-TEE keybox) can it decrypt the payload at OTA time.
function ota_payload_encryption_enabled() {
    ota_encrypted_rootfs_enabled
}

# Secure Boot authenticates both its FIT and its OTA manifest. The rootfs
# stamp lets the device enforce the same contract even when an older package
# does not declare a security tier in its metadata.
function ota_secure_boot_payload_signature_required() {
    [[ "${RK_SECURE_UBOOT_ENABLE:-no}" == "yes" ]]
}

# Resolve the secure-boot signing key directory. The keys are generated during
# the U-Boot build phase; at image/packaging time we reach them through, in
# order: a caller-supplied persistent backup dir, the export left by the
# secure-boot hook, or the original U-Boot source tree under SRC/cache/sources
# (the same cross-phase cache ota_copy_secure_boot_itb relies on for boot.itb).
function ota_resolve_signing_key_dir() {
    local candidate

    for candidate in \
        "${UBOOT_FIT_KEYS_BACKUP_DIR:-}" \
        "${UBOOT_FIT_KEYS_DIR:-}" \
        "${SRC}/cache/sources/${BOOTSOURCEDIR}/keys"
    do
        [[ -n "${candidate}" && -f "${candidate}/private_key.pem" && -f "${candidate}/public_key.pem" ]] || continue
        echo "${candidate}"
        return 0
    done

    return 1
}

function ota_resolve_signing_privkey() {
    local keys_dir
    keys_dir="$(ota_resolve_signing_key_dir)" || return 1
    echo "${keys_dir}/private_key.pem"
}

function ota_resolve_signing_pubkey() {
    local keys_dir
    keys_dir="$(ota_resolve_signing_key_dir)" || return 1
    echo "${keys_dir}/public_key.pem"
}

# Install openssl on the target. The same binary performs payload decryption
# (AES-256-CBC) and manifest signature verification (RSA-PSS) at OTA time.
function extension_prepare_config__install_ota_payload_crypto() {
    if ! ota_payload_encryption_enabled; then
        return 0
    fi
    display_alert "OTA payload security" "Installing openssl for payload decryption and signature verification" "info"
    add_packages_to_image openssl
}

# Embed the OTA payload verification public key into the rootfs so the device
# can authenticate the signed manifest. Runs before the packaging hook (901).
function pre_umount_final_image__897_install_ota_payload_pubkey() {
    local pubkey_src pubkey_dir

    if ! ota_payload_encryption_enabled; then
        return 0
    fi

    pubkey_src="$(ota_resolve_signing_pubkey 2>/dev/null)" || {
        if ota_secure_boot_payload_signature_required; then
            display_alert "OTA payload security" "Secure Boot requires an OTA signing key, but none was found" "err"
            return 1
        fi
        display_alert "OTA payload security" "Secure-boot signing key not found; payload will be encrypted but NOT signed" "warn"
        display_alert "OTA payload security" "Provide UBOOT_FIT_KEYS_BACKUP_DIR or enable OP-TEE/secure-boot key generation to sign OTA payloads" "warn"
        return 0
    }

    pubkey_dir="${MOUNT}/usr/share/armbian-ota/keys"
    mkdir -p "${pubkey_dir}"
    install -m 0644 "${pubkey_src}" "${pubkey_dir}/ota-payload.pub.pem" ||
        exit_with_error "Failed to install OTA payload verification public key"
    display_alert "OTA payload security" "Installed OTA payload verification public key into rootfs" "info"

    if ota_secure_boot_payload_signature_required; then
        printf 'SECURE_BOOT=yes\n' > "${MOUNT}/usr/share/armbian-ota/security-profile" ||
            exit_with_error "Failed to install OTA security profile"
    fi
}
