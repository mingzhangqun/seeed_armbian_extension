# Stage the rescue-default-env U-Boot patch (v0.8 design section 3.4) into
# the userpatches overlay for EVERY build flavor: the patch's bootcmd is
# self-routing (boots /recovery/ only when present, else distro_bootcmd),
# so one compiled U-Boot is correct for recovery, plain and A/B alike.

# Unconditional staging keeps a stable artifact hash across flavors
# (patches_hash covers this location; a gated patch thrashed the cache on
# flavor alternation) and no stale-patch leak window. USERPATCHES_PATH
# keeps the framework tree untouched.

# Copy a U-Boot patch from patches/ into the userpatches overlay for the
# next U-Boot compile; see the file header for why staging is unconditional.
function ota_stage_uboot_patch() {
	local patch_name="$1"
	local extension_common_root patch_src
	local boot_patch_dir target_dir

	extension_common_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	patch_src="${extension_common_root}/patches/${patch_name}"

	[[ -f "${patch_src}" ]] ||
		exit_with_error "seeed-ota" "U-Boot patch missing: ${patch_src}"

	# BOOTPATCHDIR is a space-separated list; the base family dir comes first.
	boot_patch_dir="${BOOTPATCHDIR%% *}"
	target_dir="${USERPATCHES_PATH}/u-boot/${boot_patch_dir}"

	mkdir -p "${target_dir}"
	cp -f "${patch_src}" "${target_dir}/${patch_name}"
	display_alert "seeed-ota" "staged ${patch_name} -> ${target_dir}" "info"
}

function post_family_config__seeed_ota_stage_uboot_rescue_default_env() {
	ota_stage_uboot_patch "seeed-ota-rescue-default-env.patch"
}

# Stage unconditionally: the Kconfig default activates it on BLK_DEV env
# builds; inert anywhere else.
function post_family_config__seeed_ota_stage_uboot_redundant_env() {
	ota_stage_uboot_patch "seeed-uboot-redundant-env.patch"
}
