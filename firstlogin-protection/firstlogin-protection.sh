# Patch armbian-firstlogin with power-loss protection.
# Applies on top of the stock firstlogin, adding:
#  1. Move .not_logged_in_yet deletion to end of script for re-run safety
#  2. Atomic writes (tmp→sync→mv) for sshd_config, locale.gen, /etc/default/locale,
#     netplan configs, sudoers
#  3. Idempotent locale exports and sudoers append
#  4. Prevent infinite loop when user already exists in automated mode
#  5. Skip adduser when user already exists (power-loss re-run)
#  6. Sudoers corruption repair, PermitRootLogin yes, add_user guard
function post_family_tweaks__seeed_firstlogin_install() {
	local patch_dir
	patch_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
	local patch_file="${patch_dir}/armbian-firstlogin-hardening.patch"
	local target="${SDCARD}/usr/lib/armbian/armbian-firstlogin"

	if [[ ! -f "$patch_file" ]]; then
		display_alert "Firstlogin protection" "Patch not found: $patch_file" "warn"
		return 1
	fi

	display_alert "Firstlogin protection" "Patching armbian-firstlogin with hardening" "info"
	patch --no-backup-if-mismatch -s "$target" < "$patch_file"
}

# Patch armbian-firstrun: use atomic write for armbianEnv.txt MAC randomization.
# Prevents armbianEnv.txt corruption (zero-filled) from power loss during
# first boot. Replaces non-atomic sed -i with tmp→sync→mv pattern.
function post_family_tweaks__seeed_firstrun_atomic_mac() {
	local patch_dir
	patch_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
	local patch_file="${patch_dir}/armbian-firstrun-atomic-mac.patch"
	local target="${SDCARD}/usr/lib/armbian/armbian-firstrun"

	if [[ ! -f "$patch_file" ]]; then
		display_alert "Firstrun protection" "Atomic MAC patch not found: $patch_file" "warn"
		return 1
	fi

	display_alert "Firstrun protection" "Patching armbian-firstrun for atomic MAC write" "info"
	patch --no-backup-if-mismatch -s "$target" < "$patch_file"
}

# Install SSH power-loss protection.
# Adds a systemd drop-in that runs ssh-protect as ExecStartPre for ssh.service.
# If sshd -t fails (corrupted config or host keys), the script regenerates keys.
function post_family_tweaks__seeed_ssh_protect() {
	local script_dir
	script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

	display_alert "SSH protection" "Installing ssh-protect ExecStartPre" "info"

	# Install the protection script
	install -m 0755 "${script_dir}/ssh-protect" "${SDCARD}/usr/lib/armbian/ssh-protect"

	# Install systemd drop-in
	# Clear the base unit's ExecStartPre (sshd -t) first, then run
	# ssh-protect (fixes config/keys) BEFORE sshd -t (validates config).
	# Without the empty ExecStartPre=, the base unit's sshd -t runs first
	# and aborts on broken config before ssh-protect ever executes.
	mkdir -p "${SDCARD}/etc/systemd/system/ssh.service.d"
	cat > "${SDCARD}/etc/systemd/system/ssh.service.d/armbian-ssh-protect.conf" << 'EOF'
[Service]
ExecStartPre=
ExecStartPre=/usr/lib/armbian/ssh-protect
ExecStartPre=/usr/sbin/sshd -t
EOF
}
