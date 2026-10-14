	printf '%s\n' "$value"
}
RAW_P1_START=$(table_field "$RAW_P1_LINE" start)
RAW_P1_SIZE=$(table_field "$RAW_P1_LINE" size)
RAW_P1_TYPE=$(table_field "$RAW_P1_LINE" type)
RAW_P1_UUID=$(table_field "$RAW_P1_LINE" uuid)
RAW_P2_START=$(table_field "$RAW_P2_LINE" start)
RAW_P2_SIZE=$(table_field "$RAW_P2_LINE" size)
RAW_P2_TYPE=$(table_field "$RAW_P2_LINE" type)
RAW_P2_UUID=$(table_field "$RAW_P2_LINE" uuid)
RAW_ROOT_START=$(table_field "$RAW_P3_LINE" start)
RAW_P3_TYPE=$(table_field "$RAW_P3_LINE" type)
RAW_P3_UUID=$(table_field "$RAW_P3_LINE" uuid)
[[ "$SECTOR_SIZE" =~ ^[0-9]+$ && "$RAW_ROOT_START" =~ ^[0-9]+$ ]] || fail 'cannot calculate the Combustion partition offset'
[[ -n "$RAW_DISK_GUID" && -n "$RAW_P1_START" && -n "$RAW_P1_SIZE" && -n "$RAW_P1_TYPE" && -n "$RAW_P1_UUID" && \
	-n "$RAW_P2_START" && -n "$RAW_P2_SIZE" && -n "$RAW_P2_TYPE" && -n "$RAW_P2_UUID" && \
	-n "$RAW_P3_TYPE" && -n "$RAW_P3_UUID" ]] || fail 'cannot read the raw image GPT metadata'
ROOT_SIZE_SECTORS=$((ROOT_SIZE_GIB * 1024 * 1024 * 1024 / SECTOR_SIZE))
ALIGN_SECTORS=$((1048576 / SECTOR_SIZE))
CONFIG_START=$((RAW_ROOT_START + ROOT_SIZE_SECTORS))
CONFIG_START=$(((CONFIG_START + ALIGN_SECTORS - 1) / ALIGN_SECTORS * ALIGN_SECTORS))
	# openSUSE Leap Micro and other KIWI SelfInstall images grow the root
	# partition to fill any unpartitioned space on the first boot and recreate
	# kiwi_RootPart immediately after the last partition.  That would move our
	# root partition and orphan the root filesystem.  Extend the Combustion
	# partition to the end of the disk so no free space remains and the image's
	# first-boot repartitioning is skipped.
	CONFIG_SIZE=$((DISK_SECTORS - 34 - CONFIG_START))
	(( CONFIG_SIZE >= CONFIG_SIZE_MIB * 1024 * 1024 / SECTOR_SIZE )) || \
		fail 'not enough free space for the Combustion partition'
	CONFIG_END=$((CONFIG_START + CONFIG_SIZE - 1))
case "$DISK" in
	/dev/nvme*|/dev/mmcblk*|/dev/loop*) CONFIG_PART=${DISK}p4 ;;
	*) CONFIG_PART=${DISK}4 ;;
esac
# The old kernel partition devices can survive dd and keep sfdisk from
# replacing an in-use partition entry. Remove those stale mappings before
# writing the new on-disk GPT with sgdisk.
partx -d "$DISK" 2>/dev/null || true
sgdisk --zap-all "$DISK"
sgdisk \
	--disk-guid="$RAW_DISK_GUID" \
	--new=1:"$RAW_P1_START":"$((RAW_P1_START + RAW_P1_SIZE - 1))" \
	--typecode=1:"$RAW_P1_TYPE" --partition-guid=1:"$RAW_P1_UUID" --change-name=1:p.legacy \
	--new=2:"$RAW_P2_START":"$((RAW_P2_START + RAW_P2_SIZE - 1))" \
	--typecode=2:"$RAW_P2_TYPE" --partition-guid=2:"$RAW_P2_UUID" --change-name=2:p.UEFI \
	--new=3:"$RAW_ROOT_START":"$((RAW_ROOT_START + ROOT_SIZE_SECTORS - 1))" \
	--typecode=3:"$RAW_P3_TYPE" --partition-guid=3:"$RAW_P3_UUID" --change-name=3:p.lxroot \
	--new=4:"$CONFIG_START":"$CONFIG_END" \
	--typecode=4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 --change-name=4:combustion \
	"$DISK"
sync
sgdisk --verify "$DISK" || fail "the target GPT failed verification: $DISK"
ACTUAL_ROOT=$(sfdisk --dump "$DISK" | awk -v part="${DISK}3" '$1 == part { gsub(/,/, "", $4); gsub(/,/, "", $6); print $4 " " $6; exit }')
[[ "$ACTUAL_ROOT" == "$RAW_ROOT_START $ROOT_SIZE_SECTORS" ]] || \
	fail "target GPT root partition mismatch: expected $RAW_ROOT_START/$ROOT_SIZE_SECTORS, got ${ACTUAL_ROOT:-missing}"

CONFIG_OFFSET=$((CONFIG_START * SECTOR_SIZE))
CONFIG_BYTES=$((CONFIG_SIZE * SECTOR_SIZE))
CONFIG_LOOP=$(losetup --find --show --offset "$CONFIG_OFFSET" --sizelimit "$CONFIG_BYTES" "$DISK") || \
	fail 'cannot create a loop device for the Combustion partition'
cleanup_config() {
	umount /run/config 2>/dev/null || true
	losetup -d "$CONFIG_LOOP" 2>/dev/null || true
}
trap cleanup_config EXIT
mkfs.ext4 -F -L combustion "$CONFIG_LOOP"
mkdir -p /run/config
mount "$CONFIG_LOOP" /run/config
mkdir -p /run/config/combustion
cat > /run/config/combustion/script <<COMBUSTION
#!/bin/bash
set -euxo pipefail

if [[ -d /sysroot/etc ]]; then
	ROOT=/sysroot
else
	ROOT=/
fi
echo '$TARGET_HOSTNAME' > "\$ROOT/etc/hostname"

mkdir -p "\$ROOT/etc/NetworkManager/system-connections"
cat > "\$ROOT/etc/NetworkManager/system-connections/vps2img-pivot.nmconnection" <<'NETWORK'
[connection]
id=vps2img-pivot
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
		printf '%s\n' '[connection]' 'id=vps2img-pivot' 'type=ethernet' 'autoconnect=true'
		if [[ "\$NETWORK_MATCH" == mac ]]; then
			printf 'mac-address=%s\n' "\$TARGET_MAC"
		elif [[ -n "\$SELECTED_INTERFACE" ]]; then
			printf 'interface-name=%s\n' "\$SELECTED_INTERFACE"
		fi
		printf '%s\n' '' '[ipv4]'
		printf 'method=manual\naddress1=%s,%s\ndns=%s\n' '$TARGET_IPV4_CIDR' '$TARGET_GATEWAY' '$TARGET_DNS'
		printf '%s\n' '' '[ipv6]' 'method=disabled'
	} > "\$ROOT/etc/NetworkManager/system-connections/vps2img-pivot.nmconnection"
	chmod 600 "\$ROOT/etc/NetworkManager/system-connections/vps2img-pivot.nmconnection"

mkdir -p "\$ROOT/root/.ssh"
cat > "\$ROOT/root/.ssh/authorized_keys" <<'SSHKEYS'
$AUTHORIZED_KEYS
SSHKEYS
chmod 700 "\$ROOT/root/.ssh"
chmod 600 "\$ROOT/root/.ssh/authorized_keys"

mkdir -p "\$ROOT/etc/ssh/sshd_config.d"
cat > "\$ROOT/etc/ssh/sshd_config.d/90-vps2img-pivot.conf" <<'SSHD'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
SSHD

systemctl --root="\$ROOT" enable sshd.service
systemctl --root="\$ROOT" enable NetworkManager.service

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
COMBUSTION
chmod 0700 /run/config/combustion/script
sync
umount /run/config
losetup -d "$CONFIG_LOOP"
trap - EXIT

# The image also has EFI/BOOT/BOOTX64.EFI, but an explicit NVRAM entry avoids
# depending on firmware fallback behavior after replacing a previous OS.
partx -u "$DISK" 2>/dev/null || true
if [[ -d /sys/firmware/efi ]]; then
	command -v efibootmgr >/dev/null 2>&1 || fail 'UEFI boot detected but efibootmgr is not staged'
	efibootmgr -c -d "$DISK" -p 2 -L 'vps2img-pivot' -l '\EFI\BOOT\BOOTX64.EFI' || \
		fail 'efibootmgr could not create the vps2img-pivot boot entry'
	efibootmgr -v || fail 'efibootmgr could not read the new boot entry'
else
	printf '%s\n' 'UEFI runtime unavailable; relying on the EFI fallback path or BIOS boot code.'
fi
	flush_disk
	printf '%s\n' 'Raw image written. Rebooting into the new system.'
reboot -f
INNER
	chmod 0755 "$BOOTSTRAP/run/deploy"
}

run_from_bootstrap() {
	local oldroot="$BOOTSTRAP/oldroot" mountpoint node type
	local node type mountpoint
	# EFI (/boot/efi) and any separate /boot partition must be detached before
	# the target disk is overwritten.  The inner check remains as a second
	# guard after pivot_root.
	while read -r node type; do
		[[ "$type" == part ]] || continue
		while read -r mountpoint; do
			[[ -n "$mountpoint" ]] || continue
			# The active root must move through pivot_root first.  It cannot be
			# unmounted while this shell is still running from that root.
			[[ "$mountpoint" == / ]] && continue
			umount -Rl "$mountpoint" 2>/dev/null || umount -l "$mountpoint" 2>/dev/null || \
				die "cannot detach target mount: $node at $mountpoint"
		done < <(findmnt -rn -S "$node" -o TARGET)
	done < <(lsblk -nrpo NAME,TYPE "$TARGET_DISK")
	mount --rbind /dev "$BOOTSTRAP/dev"
	mount --make-rslave "$BOOTSTRAP/dev"
	mount --rbind /proc "$BOOTSTRAP/proc"
	mount --make-rslave "$BOOTSTRAP/proc"
	mount --rbind /sys "$BOOTSTRAP/sys"
	mount --make-rslave "$BOOTSTRAP/sys"
	mkdir -p "$oldroot"
	mount --make-rprivate /
	mount --make-rprivate "$BOOTSTRAP"
	pivot_root "$BOOTSTRAP" "$oldroot"
	cd /
	for mountpoint in /oldroot/dev /oldroot/proc /oldroot/sys; do
		umount -Rl "$mountpoint" 2>/dev/null || true
	done
	# Keep /oldroot mounted until the inner deployer has flushed it and
	# switched it read-only by blockdev --setro. It then detaches it before
	# writing the new image.
	export VPS2IMG_PIVOT_ROOT_SOURCE="$ROOT_SOURCE"
	# Run the deployer as a child so the RAM bootstrap shell remains available
	# while the inner script freezes old userspace processes by name.
	/usr/bin/bash /run/deploy "$TARGET_DISK"
}

parse_args() {
	EXECUTE=0
	STAGE_TEST=0
	while (($#)); do
		case $1 in
			--image-url) IMAGE_URL=${2:?missing value for --image-url}; shift 2 ;;
			--image-file) IMAGE_FILE=${2:?missing value for --image-file}; shift 2 ;;
			--sha256) IMAGE_SHA256=${2:?missing value for --sha256}; shift 2 ;;
			--disk) TARGET_DISK=${2:?missing value for --disk}; shift 2 ;;
			--hostname) TARGET_HOSTNAME=${2:?missing value for --hostname}; shift 2 ;;
			--interface) TARGET_INTERFACE=${2:?missing value for --interface}; shift 2 ;;
			--ipv4) TARGET_IPV4_CIDR=${2:?missing value for --ipv4}; shift 2 ;;
			--gateway) TARGET_GATEWAY=${2:?missing value for --gateway}; shift 2 ;;
			--dns) TARGET_DNS=${2:?missing value for --dns}; shift 2 ;;
			--ssh-key-file) SSH_KEY_FILE=${2:?missing value for --ssh-key-file}; shift 2 ;;
			--root-size-gib) ROOT_SIZE_GIB=${2:?missing value for --root-size-gib}; shift 2 ;;
			--config-size-mib) CONFIG_SIZE_MIB=${2:?missing value for --config-size-mib}; shift 2 ;;
			--execute) EXECUTE=1; shift ;;
			--dry-run) EXECUTE=0; shift ;;
			--stage-test) EXECUTE=0; STAGE_TEST=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) die "unknown option: $1" ;;
		esac
	done
}

main() {
	parse_args "$@"
	[[ $EUID -eq 0 ]] || die 'run as root'
	check_dependencies
	discover_source
	discover_configuration
	if [[ "$IMAGE_FILE" == *.raw || "$IMAGE_URL" == *.raw ]]; then
		:
	else
		need_command unsquashfs
	fi
	prepare_image
	print_plan

	if (( STAGE_TEST )); then
		stage_bootstrap
		/usr/bin/bash -n "$BOOTSTRAP/run/deploy"
		umount -Rl "$BOOTSTRAP"
		printf '%s\n' 'STAGE-TEST: RAM bootstrap and inner deployer syntax are valid; no disk was changed.'
		return 0
	fi

	if (( ! EXECUTE )); then
		printf '%s\n' 'DRY-RUN: no disk, mount, service, or reboot operation was performed.'
		return 0
	fi
	[[ "${VPS2IMG_PIVOT_CONFIRM:-}" == "WIPE:$TARGET_DISK" ]] || \
		die "set VPS2IMG_PIVOT_CONFIRM=WIPE:$TARGET_DISK to allow the destructive operation"
	[[ "$SOURCE_DISK" == "$TARGET_DISK" ]] || warn 'target is not the current root disk; verify it before continuing'
	stage_bootstrap
	run_from_bootstrap
}

main "$@"
