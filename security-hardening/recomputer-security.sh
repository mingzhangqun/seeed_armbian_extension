#!/bin/bash

function seeed_recomputer_security_hardening_apply() {
	local board_label="${1:-reComputer}"
	local security_doc_dir="${SDCARD}/usr/share/doc/seeed-security-hardening"

	install -d -m 0755 "${SDCARD}/etc/ssh/sshd_config.d"
	cat > "${SDCARD}/etc/ssh/sshd_config.d/10-recomputer-hardening.conf" <<-'EOF'
# Seeed reComputer hardening profile:
# - lower the number of password guesses per connection
# - mitigate Terrapin by disabling chacha20-poly1305 and *-etm MACs
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 10:30:60
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com,umac-64@openssh.com
EOF

	install -d -m 0755 "${SDCARD}/etc/fail2ban/jail.d"
	cat > "${SDCARD}/etc/fail2ban/jail.d/recomputer-sshd.conf" <<-'EOF'
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
backend = auto

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
EOF

	install -d -m 0755 "${SDCARD}/etc/security"
	cat > "${SDCARD}/etc/security/faillock.conf" <<-'EOF'
# Seeed reComputer login lockout policy:
# - lock account after 5 consecutive failed passwords
# - auto-unlock after 60 seconds
deny = 5
unlock_time = 60
EOF

	# Inject pam_faillock into common-auth (preauth + authfail + authsucc)
	local common_auth="${SDCARD}/etc/pam.d/common-auth"
	if [[ -f "${common_auth}" ]] && ! grep -q 'pam_faillock' "${common_auth}"; then
		sed -i '1i auth    required                    pam_faillock.so preauth' "${common_auth}"
		sed -i '/^auth.*pam_unix.so/a auth    [default=die]               pam_faillock.so authfail\nauth    sufficient                 pam_faillock.so authsucc' "${common_auth}"
		display_alert "Security hardening" "pam_faillock injected into common-auth" "info"
	fi

	# Inject pam_faillock into common-account
	local common_account="${SDCARD}/etc/pam.d/common-account"
	if [[ -f "${common_account}" ]] && ! grep -q 'pam_faillock' "${common_account}"; then
		sed -i '/^account.*pam_unix.so/i account required                   pam_faillock.so' "${common_account}"
		display_alert "Security hardening" "pam_faillock injected into common-account" "info"
	fi

	# Bypass faillock for SSH: replace @include with inline auth/account stack
	local sshd_pam="${SDCARD}/etc/pam.d/sshd"
	if [[ -f "${sshd_pam}" ]] && grep -q '@include common-auth' "${sshd_pam}"; then
		sed -i 's|^@include common-auth|auth\t[success=1 default=ignore]\tpam_unix.so nullok\nauth\trequisite\t\t\tpam_deny.so\nauth\trequired\t\t\tpam_permit.so|' "${sshd_pam}"
		sed -i 's|^@include common-account|account\t[success=1 new_authtok_reqd=done default=ignore]\tpam_unix.so\naccount\trequisite\t\t\tpam_deny.so\naccount\trequired\t\t\tpam_permit.so|' "${sshd_pam}"
		display_alert "Security hardening" "sshd PAM bypasses faillock (IP-level ban only via fail2ban)" "info"
	fi

	install -d -m 0755 "${SDCARD}/etc/dhcp"
	cat > "${SDCARD}/etc/dhcp/dhclient.conf" <<-'EOF'
# Request only the DHCP options required for normal address assignment.
request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, interface-mtu;
EOF

	install -d -m 0755 "${SDCARD}/etc/systemd/networkd.conf.d"
	cat > "${SDCARD}/etc/systemd/networkd.conf.d/60-recomputer-dhcp-privacy.conf" <<-'EOF'
[DHCPv4]
DUIDType=link-layer

[DHCPv6]
DUIDType=link-layer
EOF

	install -d -m 0755 "${security_doc_dir}"
	local board_title="${board_label} Security Hardening"
	cat > "${security_doc_dir}/README.md" <<-'EOF'
	# BOARD_TITLE_PLACEHOLDER

	This image adds board-scoped hardening for Seeed reComputer RK3576/RK3588 builds.

	Applied at image build time:
	- SSH brute-force mitigation through fail2ban (IP-level ban, 10m)
	- SSH daemon hardening with reduced authentication retries
	- Terrapin mitigation by disabling `chacha20-poly1305@openssh.com` and Encrypt-then-MAC algorithms
	- PAM faillock: 5 failed login attempts → account locked for 60 seconds (GUI, console)
	- SSH service disabled by default (users can run `sudo systemctl enable --now ssh` after local login)
	- DHCP client data minimization for dhclient and systemd-networkd defaults

	Already provided by Armbian first boot:
	- Unique `/etc/machine-id`
	- Regenerated SSH host keys on first boot

	Not implemented at board-image layer:
	- Web UI login throttling
	- Web session timeout / auto logout
	- OTA payload signing / encryption workflow
	- HTTPS certificate provisioning for application services
	- Full DoS detection or traffic monitoring as a dedicated network appliance feature
	EOF
	sed -i "s|BOARD_TITLE_PLACEHOLDER|${board_title}|" "${security_doc_dir}/README.md"

	local unit found_ssh_unit
	found_ssh_unit="no"
	for unit in ssh.service ssh.socket; do
		if chroot_sdcard test -f "/lib/systemd/system/${unit}" || chroot_sdcard test -f "/etc/systemd/system/${unit}"; then
			found_ssh_unit="yes"
			chroot_sdcard systemctl --no-reload disable "${unit}" || display_alert "${board_label}" "Failed to disable ${unit}" "warn"
		fi
	done
	if [[ "${found_ssh_unit}" == "no" ]]; then
		display_alert "${board_label}" "No ssh service unit found in image; skipping disable" "warn"
	fi

	if chroot_sdcard test -f /lib/systemd/system/fail2ban.service || chroot_sdcard test -f /etc/systemd/system/fail2ban.service; then
		chroot_sdcard systemctl --no-reload enable fail2ban.service || display_alert "${board_label}" "Failed to enable fail2ban.service" "warn"
	else
		display_alert "${board_label}" "fail2ban.service not found in image; skipping enable" "warn"
	fi
}

function post_family_tweaks__seeed_recomputer_security_hardening() {
	display_alert "Security hardening" "Applying reComputer security hardening defaults" "info"
	seeed_recomputer_security_hardening_apply "${BOARD_NAME:-reComputer}"
}
