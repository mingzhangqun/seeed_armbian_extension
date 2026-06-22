if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${CRYPTROOT_ENABLE}" != "yes" ]]; then
	display_alert "Secure U-Boot" "RK_SECURE_UBOOT_ENABLE requires CRYPTROOT_ENABLE=yes, forcing enable" "warn"
	export CRYPTROOT_ENABLE=yes
fi

if [[ "${CRYPTROOT_ENABLE}" == "yes" ]]; then
	enable_extension "seeed_armbian_extension/rk_secure-disk-encryption/rk-cryptroot-verbosity"
fi

if [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
	display_alert "Cryptroot" "Enable RK to automatically unlock encrypted containers" "info"
	export CRYPTROOT_SSH_UNLOCK=no
	enable_extension "seeed_armbian_extension/rk_secure-disk-encryption/rk-auto-decryption-disk"
fi

if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" || "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
	if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]]; then
		display_alert "Secure U-Boot" "Enable Secure Boot Extensions" "info"
	else
		display_alert "OP-TEE bootchain" "Enable rk-secure-boot extension in OP-TEE bootchain mode" "info"
	fi
	enable_extension "seeed_armbian_extension/rk_secure-disk-encryption/rk-secure-boot"
fi

if [[ "${OTA_ENABLE}" == "yes" ]]; then
	display_alert "OTA_ENABLE" "Enable OTA extension ota-support" "info"
	enable_extension "seeed_armbian_extension/armbian-ota/ota-support"
fi

if [[ "yes" == "yes" ]]; then
	display_alert "Security hardening" "Enable security hardening extension recomputer-security" "info"
	enable_extension "seeed_armbian_extension/security-hardening/recomputer-security"
fi

if [[ "yes" == "yes" ]]; then
	display_alert "Firstlogin protection" "Enable firstlogin power-loss protection" "info"
	enable_extension "seeed_armbian_extension/firstlogin-protection/firstlogin-protection"
fi

# RK3576/RK3588 U-Boot SPL loader hooks: boot_merger + optional usbplug recompile
# for Maskrom recovery on new SPI flash boards. Hook functions are inert for SoCs
# they don't handle (they fall back to upstream mkimage behavior).
if [[ "yes" == "yes" ]]; then
	display_alert "RK U-Boot postprocess" "Enable rk-uboot-postprocess hooks" "info"
	enable_extension "seeed_armbian_extension/rk-uboot-postprocess/rk-uboot-postprocess"
fi
