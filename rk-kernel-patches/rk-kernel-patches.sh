# Stage Seeed kernel patches into the userpatches overlay.
#
# Fixes that land in Seeed's linux-rockchip branches after the Armbian vendor
# kernel mirror (armbian/linux-rockchip, branch rk-6.1-rkr7.2) took its
# snapshot are carried here as git format-patch files and staged into
# ${USERPATCHES_PATH}/kernel/${KERNELPATCHDIR} at post_family_config time —
# pre-hash, so the staged file joins the kernel artifact's patch-dir hash
# and a cached kernel build can never silently skip the fix. Staging
# unconditionally for every flavor sharing the KERNELPATCHDIR also keeps one
# stable kernel artifact hash across flavors (a per-flavor gate would bump
# the artifact version and thrash the cache whenever flavors alternate).
#
# Layout mirrors the kernel patch dirs: patches/kernel/<KERNELPATCHDIR>/.
# Staging is gated on that directory existing, so a patch carried for the
# 6.1 vendor tree is never offered to vendor-next (6.12) or edge builds,
# where it would fail to apply and break the build. Removing a patch from
# this tree also removes it from the next build's staging; a file staged by
# an older revision keeps its hash contribution until userpatches is
# cleaned, the same trade-off the rescue-default-env U-Boot patch accepts.
#
# Staging targets USERPATCHES_PATH (not SRC/patch) so the framework tree
# stays untouched (same approach as the rescue-default-env U-Boot patch).

function post_family_config__seeed_stage_kernel_patches() {
	local extension_root patch_src_dir kernel_patch_dir target_dir patch_file

	# Config dumps (CONFIG_DEFS_ONLY) run no kernel build; skip the write.
	[[ "${CONFIG_DEFS_ONLY:-}" == "yes" ]] && return 0

	extension_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# KERNELPATCHDIR is a space-separated list; the base family dir comes first.
	kernel_patch_dir="${KERNELPATCHDIR%% *}"
	patch_src_dir="${extension_root}/patches/kernel/${kernel_patch_dir}"

	# Nothing carried for this kernel (vendor-next/edge use other dirs).
	[[ -d "${patch_src_dir}" ]] || return 0

	target_dir="${USERPATCHES_PATH}/kernel/${kernel_patch_dir}"
	mkdir -p "${target_dir}"

	for patch_file in "${patch_src_dir}"/*.patch; do
		[[ -f "${patch_file}" ]] || continue
		cp -f "${patch_file}" "${target_dir}/"
		display_alert "seeed-kernel-patches" "staged $(basename "${patch_file}") -> ${target_dir}" "info"
	done
}
