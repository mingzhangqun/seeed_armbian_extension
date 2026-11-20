# Stage the Seeed rescue-default-env U-Boot patch (recovery OTA v0.8 design
# section 3.4) into the userpatches overlay for EVERY build flavor.
#
# The patch's default bootcmd is self-routing: ota_rescue_boot boots the
# /recovery/ assets only when they exist and falls through to
# distro_bootcmd otherwise, so the same compiled U-Boot is correct for
# recovery-OTA, plain and A/B images. Staging unconditionally keeps:
#   - one stable U-Boot artifact hash across flavors sharing a checkout
#     (patches_hash covers this location; a gated patch used to bump the
#     artifact version and thrash the cache whenever flavors alternated);
#   - no stale-patch risk window (the previous stage/sweep pair had to run
#     on every single build or a recovery build's patch leaked into the
#     next plain build's U-Boot).
#
# Staging targets USERPATCHES_PATH (not SRC/patch) so the framework tree
# stays untouched. The patch versions together with the rest of the v0.8
# pieces under this repository's release tags.

function post_family_config__seeed_ota_stage_uboot_rescue_default_env() {
	local extension_common_root patch_src
	local boot_patch_dir target_dir target_patch

	extension_common_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	patch_src="${extension_common_root}/patches/seeed-ota-rescue-default-env.patch"

	[[ -f "${patch_src}" ]] ||
		exit_with_error "seeed-ota" "rescue-default-env patch missing: ${patch_src}"

	# BOOTPATCHDIR is a space-separated list; the base family dir comes first.
	boot_patch_dir="${BOOTPATCHDIR%% *}"
	target_dir="${USERPATCHES_PATH}/u-boot/${boot_patch_dir}"
	target_patch="${target_dir}/seeed-ota-rescue-default-env.patch"

	mkdir -p "${target_dir}"
	cp -f "${patch_src}" "${target_patch}"
	display_alert "seeed-ota" "staged rescue-default-env U-Boot patch -> ${target_dir}" "info"
}

# Stage the redundant-env U-Boot patch for rk3576 boards. The patch makes
# CONFIG_ENV_OFFSET_REDUND selectable for the block-device env driver and
# defaults it to 0x3f0000 (the 32 KiB directly below the 0x3f8000 primary
# env; rk3576 keeps u-boot.itb at the 8 MiB raw slot, rk3588 keeps U-Boot
# in partition 1, so the raw area below holds only idbloader + env, and
# prefill's assert_layout fails the build if a loader ever crosses the
# boundary). Same BOARD => same staging decision across build flavors,
# so the U-Boot artifact hash stays stable per board.
function post_family_config__seeed_ota_stage_uboot_redundant_env() {
	local extension_common_root patch_src
	local boot_patch_dir target_dir target_patch

	case "${BOOT_SOC:-}" in
		rk3576 | rk3588) ;;
		*)
			display_alert "seeed-ota" "redundant env patch skipped (BOOT_SOC=${BOOT_SOC:-none})" "info"
			return 0
			;;
	esac

	extension_common_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	patch_src="${extension_common_root}/patches/seeed-uboot-redundant-env.patch"

	[[ -f "${patch_src}" ]] ||
		exit_with_error "seeed-ota" "redundant-env patch missing: ${patch_src}"

	boot_patch_dir="${BOOTPATCHDIR%% *}"
	target_dir="${USERPATCHES_PATH}/u-boot/${boot_patch_dir}"
	target_patch="${target_dir}/seeed-uboot-redundant-env.patch"

	mkdir -p "${target_dir}"
	cp -f "${patch_src}" "${target_patch}"
	display_alert "seeed-ota" "staged redundant-env U-Boot patch -> ${target_dir}" "info"
}
