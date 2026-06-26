# Seeed reComputer RK35xx: U-Boot SPL loader post-processing hooks.
#
# These hooks are invoked by rockchip64_common.inc::uboot_custom_postprocess()
# when the Seeed extension is enabled (ENABLE_SEEED_RK_EXTENSION=yes). They add
# Maskrom-recovery support on top of upstream behavior:
#   - boot_merger-based spl_loader generation for RK3576/RK3588
#   - optional usbplug recompile from patched U-Boot source (RK_COMPILE_USBPLUG=yes)
#     for new SPI flash vendor support (sfc.c unaligned access fix + vendor configs)
#   - idbloader.img generation via mkimage (RK3588, whose INI lacks CREATE_IDB)
#   - maskrom spl_loader always saved as spl_loader_maskrom.bin in the U-Boot
#     source dir, picked up by board_uboot_spi_image_after_build and shipped in
#     the u-boot deb under /usr/lib/linux-u-boot-<branch>-<board>/. Uses the
#     rkbin-tools usbplug blob by default; RK_COMPILE_USBPLUG=yes swaps in a
#     usbplug recompiled from patched U-Boot source for new SPI flash vendor
#     support.
#
# When this extension is NOT loaded, rockchip64_common.inc falls back to upstream
# behavior (RK3576: basic boot_merger; RK3588 and others: mkimage-only fallback).

# Hook invoked from uboot_custom_postprocess() spl-blobs case.
# Args: $1 = BOOT_SOC, $2 = SPL_BIN_PATH (DDR blob), $3 = FLASH_BOOT_BIN (mainline
# ./spl/u-boot-spl.bin or vendor VENDOR_SPL_PATH for vendor-spl-blobs scenario).
board_uboot_spl_blobs_postprocess() {
	local boot_soc="$1"
	local spl_bin_path="$2"
	local flash_boot_bin="$3"

	case "$boot_soc" in
		rk3576)
			_seeed_rk3576_spl_loader "$spl_bin_path" "$flash_boot_bin"
			;;
		rk3588)
			_seeed_rk3588_spl_loader "$spl_bin_path" "$flash_boot_bin"
			;;
		*)
			# Fallback to upstream mkimage path for any other SoC (defensive; the
			# extension is only enabled for Seeed rk3576/rk3588 boards in practice).
			display_alert "mkimage for '${boot_soc}' (Seeed hook fallback)" "SPL_BIN_PATH: ${spl_bin_path}" "debug"
			run_host_command_logged tools/mkimage -n "${BOOT_SOC_MKIMAGE}" -T rksd \
				-d "${spl_bin_path}:spl/u-boot-spl.bin" idbloader.img
			;;
	esac
}

# Hook invoked from rockchip64_common.inc::uboot_custom_postprocess() after
# rkspi_loader.img has been assembled (BOOT_SUPPORT_SPI=yes &&
# BOOT_SPI_RKSPI_LOADER=yes). Adds the maskrom spl_loader (built by
# _seeed_rk35xx_spl_loader and saved as spl_loader_maskrom.bin in the U-Boot
# source dir) to target_files so it ships in the u-boot deb under
# /usr/lib/linux-u-boot-<branch>-<board>/.
board_uboot_spi_image_after_build() {
	if [[ -f spl_loader_maskrom.bin ]]; then
		target_files+=" spl_loader_maskrom.bin"
		display_alert "maskrom spl_loader added to u-boot deb" \
			"$(du -h spl_loader_maskrom.bin | cut -f1)" "info"
	fi
}

# --- RK3576: boot_merger from RK3576MINIALL.ini + optional usbplug recompile ---
_seeed_rk3576_spl_loader() {
	local spl_bin_path="$1"
	local flash_boot_bin="$2"

	display_alert "boot_merger for 'rk3576' for scenario ${BOOT_SCENARIO}" \
		"SPL_BIN_PATH: ${spl_bin_path}" "debug"
	local rkboot_ini=rk3576.ini
	cp $RKBIN_DIR/rk35/RK3576MINIALL.ini $rkboot_ini
	sed -i "s|FlashBoost=.*$|FlashBoost=${RKBIN_DIR}/rk35/rk3576_boost_v1.02.bin|g" $rkboot_ini
	sed -i "s|Path1=.*rk3576_ddr.*$|Path1=${spl_bin_path}|g" $rkboot_ini

	# Default: rkbin-tools usbplug blob. Optionally recompile from patched U-Boot
	# source for new SPI flash vendor support.
	local usbplug_path="${RKBIN_DIR}/rk35/rk3576_usbplug_v1.03.bin"
	if [[ "${RK_COMPILE_USBPLUG:-no}" == "yes" ]]; then
		_seeed_compile_usbplug rk3576
		usbplug_path="${USBPLUG_BUILT_PATH}"
	fi
	sed -i "s|Path1=.*rk3576_usbplug.*$|Path1=${usbplug_path}|g" $rkboot_ini

	sed -i "s|FlashData=.*$|FlashData=${spl_bin_path}|g" $rkboot_ini
	sed -i "s|FlashBoot=.*$|FlashBoot=${flash_boot_bin}|g" $rkboot_ini
	sed -i "s|IDB_PATH=.*$|IDB_PATH=idbloader.img|g" $rkboot_ini
	run_host_x86_binary_logged $RKBIN_DIR/tools/boot_merger $rkboot_ini
	rm -f $rkboot_ini

	# Always save spl_loader under a stable name so the
	# board_uboot_spi_image_after_build hook can pick it up and ship it in
	# the u-boot deb. Uses rkbin blob usbplug by default; compiled usbplug
	# (if RK_COMPILE_USBPLUG=yes) was already substituted into usbplug_path above.
	cp rk3576_spl_loader_*.bin spl_loader_maskrom.bin 2>/dev/null && {
		display_alert "maskrom spl_loader ready for deb packaging" \
			"$(du -h spl_loader_maskrom.bin | cut -f1)" "info"
	}
}

# --- RK3588: inline INI (rkbin-tools has no RK3588MINIALL.ini) + boot_merger ---
_seeed_rk3588_spl_loader() {
	local spl_bin_path="$1"
	local flash_boot_bin="$2"

	display_alert "boot_merger for 'rk3588' for scenario ${BOOT_SCENARIO}" \
		"SPL_BIN_PATH: ${spl_bin_path}" "debug"
	local rkboot_ini=rk3588.ini
	# RK3588 MINIALL INI not in rkbin-tools; create inline (no FlashBoost, 2 loader parts)
	cat > $rkboot_ini << 'RK3588EOF'
[CHIP_NAME]
NAME=RK3588
[VERSION]
MAJOR=1
MINOR=11
[CODE471_OPTION]
NUM=1
Path1=__DDR_PATH__
Sleep=1
[CODE472_OPTION]
NUM=1
Path1=__USBPLUG_PATH__
[LOADER_OPTION]
NUM=2
LOADER1=FlashData
LOADER2=FlashBoot
FlashData=__DDR_PATH__
FlashBoot=__SPL_PATH__
[OUTPUT]
PATH=rk3588_spl_loader.bin
[SYSTEM]
NEWIDB=true
[FLAG]
471_RC4_OFF=true
RC4_OFF=true
[BOOT1_PARAM]
WORD_0=0x0
WORD_1=0x0
WORD_2=0x0
WORD_3=0x0
WORD_4=0x0
WORD_5=0x0
WORD_6=0x0
WORD_7=0x0
RK3588EOF
	sed -i "s|__DDR_PATH__|${spl_bin_path}|g" $rkboot_ini
	sed -i "s|__SPL_PATH__|${flash_boot_bin}|g" $rkboot_ini

	# Default: rkbin-tools usbplug blob. Optionally recompile from patched U-Boot
	# source for new SPI flash vendor support.
	local usbplug_path="${RKBIN_DIR}/rk35/rk3588_usbplug_v1.11.bin"
	if [[ "${RK_COMPILE_USBPLUG:-no}" == "yes" ]]; then
		_seeed_compile_usbplug rk3588
		usbplug_path="${USBPLUG_BUILT_PATH}"
	fi
	sed -i "s|__USBPLUG_PATH__|${usbplug_path}|g" $rkboot_ini

	run_host_x86_binary_logged $RKBIN_DIR/tools/boot_merger $rkboot_ini
	rm -f $rkboot_ini
	# boot_merger creates spl_loader but not idbloader.img; create it with mkimage
	# (RK3588 INI lacks CREATE_IDB, and adding it corrupts the spl_loader format)
	run_host_command_logged tools/mkimage -n "${BOOT_SOC_MKIMAGE}" -T rksd \
		-d "${spl_bin_path}:spl/u-boot-spl.bin" idbloader.img

	# Always save spl_loader under a stable name so the
	# board_uboot_spi_image_after_build hook can pick it up and ship it in
	# the u-boot deb. Uses rkbin blob usbplug by default; compiled usbplug
	# (if RK_COMPILE_USBPLUG=yes) was already substituted into usbplug_path above.
	cp rk3588_spl_loader*.bin spl_loader_maskrom.bin 2>/dev/null && {
		display_alert "maskrom spl_loader ready for deb packaging" \
			"$(du -h spl_loader_maskrom.bin | cut -f1)" "info"
	}
}

# Compile usbplug from patched U-Boot source for new SPI flash vendor support.
# Args: $1 = SoC ("rk3576" or "rk3588"). Sets the global USBPLUG_BUILT_PATH to
# the built usbplug.bin path (avoids command-substitution capturing build output).
# Uses ARCH=arm (usbplug is always 32-bit, even on arm64 SoCs).
# Saves/restores the main U-Boot .config around the usbplug build.
_seeed_compile_usbplug() {
	local soc="$1"
	display_alert "Compiling usbplug from source" "${soc} Maskrom recovery" "info"

	# Save current build config
	cp .config .config.main_uboot

	# Configure for usbplug (ARCH=arm covers both arm32/arm64 SoCs)
	run_host_command_logged CCACHE_BASEDIR="$(pwd)" \
		pipetty make "rockchip-usbplug_defconfig" "${cross_compile}" "ARCH=arm"
	run_host_command_logged scripts/kconfig/merge_config.sh -m .config "configs/${soc}-usbplug.config"

	# RK3588 usbplug config disables SPI flash support, but Maskrom SPI NOR recovery
	# needs it. RK3576 config already has it enabled.
	if [[ "$soc" == "rk3588" ]]; then
		sed -i 's/# CONFIG_ROCKCHIP_SFC is not set/CONFIG_ROCKCHIP_SFC=y/' .config
		sed -i 's/# CONFIG_MTD is not set/CONFIG_MTD=y/' .config
		sed -i 's/# CONFIG_MTD_BLK is not set/CONFIG_MTD_BLK=y/' .config
		sed -i 's/# CONFIG_MTD_DEVICE is not set/CONFIG_MTD_DEVICE=y/' .config
		sed -i 's/# CONFIG_SPI_FLASH is not set/CONFIG_SPI_FLASH=y/' .config
	fi

	run_host_command_logged CCACHE_BASEDIR="$(pwd)" \
		pipetty make "olddefconfig" "${cross_compile}" "ARCH=arm"
	sed -i 's/-Werror//g' Makefile scripts/Makefile.build

	# Build usbplug
	run_host_command_logged CCACHE_BASEDIR="$(pwd)" \
		pipetty make "${CTHREADS}" "${cross_compile}" "ARCH=arm"

	USBPLUG_BUILT_PATH="$(pwd)/usbplug.bin"
	display_alert "usbplug compiled" "$(du -h ${USBPLUG_BUILT_PATH} | cut -f1)" "info"

	# Restore original U-Boot config
	cp .config.main_uboot .config
	rm -f .config.main_uboot
}
