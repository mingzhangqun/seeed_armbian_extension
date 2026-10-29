SEEED_EXTENSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# U-Boot default-environment helpers must exist for every build flavor,
# including standalone `compile.sh uboot` runs (CI) with no OTA_* variables:
# the packaging hook inside ships u-boot-default.env in the u-boot deb, which
# image builds later need for boot-env prefill and A/B initial-env merging.
# shellcheck source=/dev/null
source "${SEEED_EXTENSION_ROOT}/armbian-ota/common/build-hooks/uboot-default-env.sh"

if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
	exit_with_error "RK_SECURE_UBOOT_ENABLE and RK_OPTEE_BOOT_ENABLE are mutually exclusive" "use secure-boot or secure-rootfs, not both"
fi

if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" || "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
	export CRYPTROOT_ENABLE=yes
	export RK_AUTO_DECRYP=yes
fi

if [[ "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" && "${RK_OPTEE_BOOT_ENABLE}" != "yes" ]]; then
	exit_with_error "RK_AUTO_DECRYP requires an explicit boot security mode" "set RK_OPTEE_BOOT_ENABLE=yes or RK_SECURE_UBOOT_ENABLE=yes"
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
		display_alert "OP-TEE bootchain" "Enable secure boot build hooks in OP-TEE bootchain mode" "info"
	fi
	enable_extension "seeed_armbian_extension/rk_secure-disk-encryption/rk-secure-boot"
fi

# Central default for the OTA package payload format. Every build path
# (build.sh wrapper, CI, bare compile.sh) funnels through this file before
# ota-support sources package-create.sh. Override per build via
# OTA_PAYLOAD_COMP=gz|zstd comes from the environment or build.sh --ota-format.
# The DEFAULT lives in armbian-ota/common/build-hooks/package-create.sh
# (zstd for plain recovery v0.8 -- same format as the on-device lazy backup;
# xz for A/B). Only forward explicitly set values, never pin one here.
[[ -n "${OTA_PAYLOAD_COMP:-}" ]] && export OTA_PAYLOAD_COMP

if [[ "${OTA_ENABLE}" == "yes" ]]; then
	display_alert "OTA_ENABLE" "Enable OTA extension ota-support" "info"
	enable_extension "seeed_armbian_extension/armbian-ota/ota-support"
fi

if [[ "yes" == "yes" ]]; then
	display_alert "Security hardening" "Enable security hardening extension recomputer-security" "info"
	enable_extension "seeed_armbian_extension/security-hardening/recomputer-security"
fi

# SSH power-loss recovery: run the ssh-protect repair script as ExecStartPre
# of ssh.service in every seeed image.
if [[ "yes" == "yes" ]]; then
	display_alert "SSH protection" "Enable ssh-protect power-loss recovery" "info"
	enable_extension "seeed_armbian_extension/ssh-protect/ssh-protect"
fi

# Maskrom-recovery U-Boot hooks (boot_merger + compiled usbplug + spl_loader
# packaging). Opt-in: unless RK_COMPILE_USBPLUG=yes, upstream postprocess runs.
if [[ "${RK_COMPILE_USBPLUG:-no}" == "yes" ]]; then
	display_alert "RK U-Boot postprocess" "Enable rk-uboot-postprocess hooks (Maskrom loader)" "info"
	enable_extension "seeed_armbian_extension/rk-uboot-postprocess/rk-uboot-postprocess"
fi

# Anchor root= resolution to the actual boot disk in every image flavor. The
# init-top script is picked up by mkinitramfs from /etc/initramfs-tools and is
# a no-op without the armbian.bootdev cmdline token (single-disk/legacy boots).
#
# post_customize_image runs in the rootfs stage, where the working rootfs is
# ${SDCARD}; ${MOUNT} is only the loop-mounted final image later, during the
# image stage. Writing to ${MOUNT} here dropped the file into an empty staging
# dir and it never reached the image (rootfs-then-initrd rebuild both missed
# it), so every multi-disk build silently shipped without the anchor.
function post_customize_image__020_install_bootdev_root_anchor() {
	install -D -m 0755 \
		"${SEEED_EXTENSION_ROOT}/initramfs/scripts/init-top/armbian-bootdev-root" \
		"${SDCARD}/etc/initramfs-tools/scripts/init-top/armbian-bootdev-root" ||
		exit_with_error "Failed to install bootdev root anchor"

	display_alert "Bootdev root anchor" "Installed init-top armbian-bootdev-root" "info"
}

# Add the PCIe ASPM workaround to the generated image's kernel command line.
# Keep any board- or user-provided extraargs intact and make this hook idempotent.
# Same rootfs-stage rule as above: ${SDCARD}, not ${MOUNT}.
function post_customize_image__010_disable_pcie_aspm() {
	local armbian_env="${SDCARD}/boot/armbianEnv.txt"
	local line
	local extraargs=""

	mkdir -p "${SDCARD}/boot"
	touch "${armbian_env}"

	while IFS= read -r line; do
		if [[ "${line}" == extraargs=* ]]; then
			extraargs="${line#extraargs=}"
			break
		fi
	done < "${armbian_env}"

	if [[ " ${extraargs} " == *" pcie_aspm=off "* ]]; then
		return 0
	fi

	if [[ -n "${extraargs}" ]]; then
		sed -i '0,/^extraargs=/{/^extraargs=/s|$| pcie_aspm=off|}' "${armbian_env}"
	else
		if grep -q '^extraargs=' "${armbian_env}"; then
			sed -i '0,/^extraargs=/{/^extraargs=/s|$|pcie_aspm=off|}' "${armbian_env}"
		else
			printf 'extraargs=pcie_aspm=off\n' >> "${armbian_env}"
		fi
	fi

	display_alert "PCIe ASPM" "Added pcie_aspm=off to armbianEnv.txt" "info"
}
