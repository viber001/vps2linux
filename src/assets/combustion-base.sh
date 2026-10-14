#!/bin/bash
set -euxo pipefail

if [[ -d /sysroot/etc ]]; then
	ROOT=/sysroot
else
	ROOT=/
fi
echo '$TARGET_HOSTNAME' > "\$ROOT/etc/hostname"

mkdir -p "\$ROOT/etc/NetworkManager/system-connections"
cat > "\$ROOT/etc/NetworkManager/system-connections/@PROGRAM@.nmconnection" <<'NETWORK'
[connection]
id=@PROGRAM@
type=ethernet
autoconnect=true

[802-3-ethernet]
mac-address=$TARGET_MAC

[ipv4]
method=manual
address1=$TARGET_IPV4_CIDR,$TARGET_GATEWAY
dns=$TARGET_DNS

[ipv6]
method=disabled
NETWORK

	# Prefer the saved bridge member MAC. If the target kernel exposes a
	# different predictable name, NetworkManager can still match the device by
	# MAC. If that fails, use the saved member/altnames, then the first UP NIC.
	TARGET_INTERFACE_NAMES='$TARGET_INTERFACE_NAMES'
	TARGET_MAC='$TARGET_MAC'
	find_by_mac() {
		local path name address
		for path in /sys/class/net/*; do
			[[ -r "\$path/address" ]] || continue
			name=\${path##*/}
			[[ "\$name" == lo ]] && continue
			address=\$(tr '[:upper:]' '[:lower:]' < "\$path/address")
			if [[ "\$address" == "\$TARGET_MAC" ]]; then
				printf '%s\n' "\$name"
				return 0
			fi
		done
		return 1
	}
	find_by_name() {
		local candidate old_ifs=\$IFS
		IFS=,
		for candidate in \$TARGET_INTERFACE_NAMES; do
			if [[ -d "/sys/class/net/\$candidate" && "\$candidate" != lo ]]; then
				printf '%s\n' "\$candidate"
				IFS=\$old_ifs
				return 0
			fi
		done
		IFS=\$old_ifs
		return 1
	}
	find_first_up() {
		local path name state
		for path in /sys/class/net/*; do
			[[ -r "\$path/operstate" ]] || continue
			name=\${path##*/}
			[[ "\$name" == lo ]] && continue
			state=\$(cat "\$path/operstate" 2>/dev/null || true)
			if [[ "\$state" == up ]]; then
				printf '%s\n' "\$name"
				return 0
			fi
		done
		return 1
	}
	SELECTED_INTERFACE=\$(find_by_mac || true)
	NETWORK_MATCH=mac
	if [[ -z "\$SELECTED_INTERFACE" ]]; then
		SELECTED_INTERFACE=\$(find_by_name || true)
		NETWORK_MATCH=name
	fi
	if [[ -z "\$SELECTED_INTERFACE" ]]; then
		SELECTED_INTERFACE=\$(find_first_up || true)
		NETWORK_MATCH=name
	fi
	{
		printf '%s\n' '[connection]' 'id=@PROGRAM@' 'type=ethernet' 'autoconnect=true'
		if [[ "\$NETWORK_MATCH" == mac ]]; then
			printf 'mac-address=%s\n' "\$TARGET_MAC"
		elif [[ -n "\$SELECTED_INTERFACE" ]]; then
			printf 'interface-name=%s\n' "\$SELECTED_INTERFACE"
		fi
		printf '%s\n' '' '[ipv4]'
		printf 'method=manual\naddress1=%s,%s\ndns=%s\n' '$TARGET_IPV4_CIDR' '$TARGET_GATEWAY' '$TARGET_DNS'
		printf '%s\n' '' '[ipv6]' 'method=disabled'
	} > "\$ROOT/etc/NetworkManager/system-connections/@PROGRAM@.nmconnection"
	chmod 600 "\$ROOT/etc/NetworkManager/system-connections/@PROGRAM@.nmconnection"

mkdir -p "\$ROOT/root/.ssh"
cat > "\$ROOT/root/.ssh/authorized_keys" <<'SSHKEYS'
$AUTHORIZED_KEYS
SSHKEYS
chmod 700 "\$ROOT/root/.ssh"
chmod 600 "\$ROOT/root/.ssh/authorized_keys"

# Mirror kernel and systemd output to the VGA console in addition to the serial
# console, so the boot is visible on the PVE web console even when the serial
# console is not attached. The image already carries console=tty0 in
# GRUB_CMDLINE_LINUX_DEFAULT, but its generated grub.cfg omitted it; patch the
# effective grub.cfg directly and update the bootloader defaults so later
# grub2-mkconfig runs keep the setting. Effective from the next boot.
if [[ -f "\$ROOT/boot/grub2/grub.cfg" ]] && ! grep -q 'console=tty0' "\$ROOT/boot/grub2/grub.cfg"; then
	sed -i 's/console=ttyS0,115200/console=ttyS0,115200 console=tty0/g' "\$ROOT/boot/grub2/grub.cfg"
fi
if [[ -f "\$ROOT/etc/default/grub" ]] && ! grep -q 'console=tty0' "\$ROOT/etc/default/grub"; then
	sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 console=tty0"/' "\$ROOT/etc/default/grub"
fi
if [[ -f "\$ROOT/etc/sysconfig/bootloader" ]] && ! grep -q 'console=tty0' "\$ROOT/etc/sysconfig/bootloader"; then
	sed -i 's/^\(DEFAULT_APPEND="[^"]*\)"/\1 console=tty0"/; s/^\(FAILSAFE_APPEND="[^"]*\)"/\1 console=tty0"/' "\$ROOT/etc/sysconfig/bootloader"
fi

