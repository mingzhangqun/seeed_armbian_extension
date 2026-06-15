# Patch armbian-common: extract atomic_write() as a shared library.
# Must be applied BEFORE armbian-firstlogin patch, since firstlogin now
# sources armbian-common for atomic_write() instead of defining it inline.
function post_family_tweaks__seeed_armbian_common_atomic_write() {
	local patch_dir
	patch_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
	local patch_file="${patch_dir}/armbian-common-atomic-write.patch"
	local target="${SDCARD}/usr/lib/armbian/armbian-common"

	if [[ ! -f "$patch_file" ]]; then
		display_alert "armbian-common" "Patch not found: $patch_file" "warn"
		return 1
	fi

	display_alert "armbian-common" "Adding atomic_write() shared library" "info"
	patch --no-backup-if-mismatch -s "$target" < "$patch_file"
}

# Patch armbian-firstrun: use shared atomic_write() for MAC address write.
# Replaces inline sed/chmod/sync/mv chain with the shared atomic_write()
# function from armbian-common.
function post_family_tweaks__seeed_firstrun_atomic_write() {
	local patch_dir
	patch_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
	local patch_file="${patch_dir}/armbian-firstrun-atomic-write.patch"
	local target="${SDCARD}/usr/lib/armbian/armbian-firstrun"

	if [[ ! -f "$patch_file" ]]; then
		display_alert "armbian-firstrun" "Patch not found: $patch_file" "warn"
		return 1
	fi

	display_alert "armbian-firstrun" "Using shared atomic_write() for MAC write" "info"
	patch --no-backup-if-mismatch -s "$target" < "$patch_file"
}

# Patch armbian-firstlogin with power-loss protection.
# Applies on top of the stock firstlogin, adding:
#  1. Source armbian-common for shared atomic_write()
#  2. Move .not_logged_in_yet deletion to end of script for re-run safety
#  3. Atomic writes (tmp→sync→mv) for sshd_config, locale.gen, /etc/default/locale,
#     netplan configs, sudoers, useradd, adduser.conf
#  4. Idempotent locale exports and sudoers append
#  5. Prevent infinite loop when user already exists in automated mode
#  6. Skip adduser when user already exists (power-loss re-run)
#  7. Sudoers corruption repair, add_user guard
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
