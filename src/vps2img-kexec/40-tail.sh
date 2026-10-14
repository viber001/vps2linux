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
	-n "$RAW_P3_TYPE" && -n "$RAW_P3_UUID" ]] || fail 'cannot read the raw image GPT metadata from the disk'
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
# The kernel partition devices scanned at boot describe the old PVE layout.
# The image was just written, so remove any stale mapping before sgdisk.
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
# Assert the Combustion partition exists and no >10 MiB hole is left: openSUSE
# Leap Micro's first boot (55kiwi-repart) relocates kiwi_RootPart and drops
# this partition whenever more than ~10 MiB of unpartitioned space is free.
ACTUAL_CONFIG=$(sfdisk --dump "$DISK" | awk -v part="${DISK}4" '$1 == part { print $1 }')
[[ -n "$ACTUAL_CONFIG" ]] || fail 'the Combustion partition was not created'
LAST_USABLE=$((DISK_SECTORS - 34))
FREE_SECTORS=$((LAST_USABLE - CONFIG_END))
(( FREE_SECTORS * SECTOR_SIZE < 10 * 1024 * 1024 )) || \
	fail "target disk still has ${FREE_SECTORS} free sectors; Leap Micro would repartition it"

CONFIG_OFFSET=$((CONFIG_START * SECTOR_SIZE))
CONFIG_BYTES=$((CONFIG_SIZE * SECTOR_SIZE))
CONFIG_LOOP=$(losetup --find --show --offset "$CONFIG_OFFSET" --sizelimit "$CONFIG_BYTES" "$DISK") || \
	fail 'cannot create a loop device for the Combustion partition'
cleanup_config() {
	umount /config 2>/dev/null || true
	losetup -d "$CONFIG_LOOP" 2>/dev/null || true
}
trap cleanup_config EXIT
mke2fs -F -t ext4 -L combustion "$CONFIG_LOOP"
mkdir -p /config
mount "$CONFIG_LOOP" /config
mkdir -p /config/combustion

# sshd policy: password authentication is enabled only when a password was
# requested, and root password login only when the requested user is root.
SSHD_PASSWORD_AUTH=no
SSHD_ROOT_LOGIN=prohibit-password
if [[ -n "$TARGET_PASSWORD" ]]; then
	SSHD_PASSWORD_AUTH=yes
	[[ "$TARGET_USER" != root ]] || SSHD_ROOT_LOGIN=yes
fi

cat > /config/combustion/script <<COMBUSTION
#!/bin/bash
set -euxo pipefail

if [[ -d /sysroot/etc ]]; then
	ROOT=/sysroot
else
	ROOT=/
fi
echo '$TARGET_HOSTNAME' > "\$ROOT/etc/hostname"

mkdir -p "\$ROOT/etc/NetworkManager/system-connections"
cat > "\$ROOT/etc/NetworkManager/system-connections/vps2img-kexec.nmconnection" <<'NETWORK'
[connection]
id=vps2img-kexec
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
		printf '%s\n' '[connection]' 'id=vps2img-kexec' 'type=ethernet' 'autoconnect=true'
		if [[ "\$NETWORK_MATCH" == mac ]]; then
			printf 'mac-address=%s\n' "\$TARGET_MAC"
		elif [[ -n "\$SELECTED_INTERFACE" ]]; then
			printf 'interface-name=%s\n' "\$SELECTED_INTERFACE"
		fi
		printf '%s\n' '' '[ipv4]'
		printf 'method=manual\naddress1=%s,%s\ndns=%s\n' '$TARGET_IPV4_CIDR' '$TARGET_GATEWAY' '$TARGET_DNS'
		printf '%s\n' '' '[ipv6]' 'method=disabled'
	} > "\$ROOT/etc/NetworkManager/system-connections/vps2img-kexec.nmconnection"
	chmod 600 "\$ROOT/etc/NetworkManager/system-connections/vps2img-kexec.nmconnection"

mkdir -p "\$ROOT/root/.ssh"
cat > "\$ROOT/root/.ssh/authorized_keys" <<'SSHKEYS'
$AUTHORIZED_KEYS
SSHKEYS
chmod 700 "\$ROOT/root/.ssh"
chmod 600 "\$ROOT/root/.ssh/authorized_keys"

# Provision the requested login user, its password and its SSH key. Leap
# Micro's Combustion chroots into the target root before running this script
# (so ROOT is usually /); when a /sysroot layout is used instead, run the
# account tools through chroot so they still act on the target.
TARGET_USER='$TARGET_USER'
TARGET_PASSWORD='$TARGET_PASSWORD'
run_in_target() {
	if [[ "\$ROOT" == / ]]; then
		"\$@"
	else
		chroot "\$ROOT" "\$@"
	fi
}
ensure_user() {
	local user=\$TARGET_USER home uid_gid
	if [[ "\$user" != root ]] && ! grep -q "^\$user:" "\$ROOT/etc/passwd"; then
		run_in_target /usr/sbin/useradd -m -s /bin/bash "\$user" || \
			run_in_target /usr/sbin/useradd -m "\$user"
	fi
	if [[ -n "\$TARGET_PASSWORD" ]]; then
		printf '%s:%s\n' "\$user" "\$TARGET_PASSWORD" | run_in_target /usr/sbin/chpasswd
	fi
	home=\$(awk -F: -v u="\$user" '\$1==u{print \$6}' "\$ROOT/etc/passwd")
	[[ -n "\$home" ]] || home=/root
	uid_gid=\$(awk -F: -v u="\$user" '\$1==u{print \$3":"\$4}' "\$ROOT/etc/passwd")
	mkdir -p "\$ROOT\$home/.ssh"
	cat > "\$ROOT\$home/.ssh/authorized_keys" <<'USERKEYS'
$AUTHORIZED_KEYS
USERKEYS
	chmod 700 "\$ROOT\$home/.ssh"
	chmod 600 "\$ROOT\$home/.ssh/authorized_keys"
	if [[ -n "\$uid_gid" ]]; then
		chown -R "\$uid_gid" "\$ROOT\$home/.ssh"
	fi
	# /home is a separate btrfs subvolume on Leap Micro and is NOT part of a
	# transactional-update snapshot, so a key written under the user home here
	# is shadowed on the first real boot. /etc IS captured by the snapshot, so
	# also install the key under /etc/ssh/authorized_keys.d and let sshd read it
	# (AuthorizedKeysFile drop-in below); a firstboot unit recreates the real
	# ~/.ssh on the /home subvolume.
	mkdir -p "\$ROOT/etc/ssh/authorized_keys.d"
	cat > "\$ROOT/etc/ssh/authorized_keys.d/\$user" <<'USERKEYS'
$AUTHORIZED_KEYS
USERKEYS
	chmod 644 "\$ROOT/etc/ssh/authorized_keys.d/\$user"
	chown root:root "\$ROOT/etc/ssh/authorized_keys.d/\$user"
	chmod 755 "\$ROOT/etc/ssh/authorized_keys.d"
}
ensure_user

# The user home lives on the /home subvolume, which Combustion cannot write
# (see above). Materialize ~/.ssh there on the first real boot from the copy
# under /etc, so the requested user ends up with a working authorized_keys.
if [[ '$TARGET_USER' != root ]]; then
	mkdir -p "\$ROOT/etc/systemd/system"
	cat > "\$ROOT/etc/systemd/system/vps2img-kexec-user-home.service" <<UNIT
[Unit]
Description=Create home and SSH authorized_keys for $TARGET_USER
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/install -d -m 0700 -o $TARGET_USER -g $TARGET_USER /home/$TARGET_USER/.ssh
ExecStart=/usr/bin/install -m 0600 -o $TARGET_USER -g $TARGET_USER /etc/ssh/authorized_keys.d/$TARGET_USER /home/$TARGET_USER/.ssh/authorized_keys
ExecStart=/usr/bin/chown -R $TARGET_USER:$TARGET_USER /home/$TARGET_USER

[Install]
WantedBy=multi-user.target
UNIT
	systemctl --root="\$ROOT" enable vps2img-kexec-user-home.service
fi

mkdir -p "\$ROOT/etc/ssh/sshd_config.d"
cat > "\$ROOT/etc/ssh/sshd_config.d/90-vps2img-kexec.conf" <<SSHD
PermitRootLogin $SSHD_ROOT_LOGIN
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u
PasswordAuthentication $SSHD_PASSWORD_AUTH
SSHD

# Add the created user to wheel and let the group run sudo with the caller's
# own password. openSUSE ships `Defaults targetpw`, so a plain `%wheel` rule
# would still ask for ROOT's password; override it for the group.
if [[ '$TARGET_USER' != root ]]; then
	run_in_target usermod -aG wheel '$TARGET_USER' 2>/dev/null || \
		run_in_target gpasswd -a '$TARGET_USER' wheel 2>/dev/null || true
	if [[ -e "\$ROOT/usr/etc/sudoers" || -e "\$ROOT/etc/sudoers" ]]; then
		mkdir -p "\$ROOT/etc/sudoers.d"
		cat > "\$ROOT/etc/sudoers.d/wheel" <<'SUDOERS'
Defaults:%wheel !targetpw
%wheel ALL=(ALL:ALL) ALL
SUDOERS
		chmod 0440 "\$ROOT/etc/sudoers.d/wheel"
		chown root:root "\$ROOT/etc/sudoers.d/wheel"
	fi
fi

systemctl --root="\$ROOT" enable sshd.service
systemctl --root="\$ROOT" enable NetworkManager.service

# Grow the root filesystem to fill its partition. The deployer normally does
# this before the first boot; this is a fallback for a source host without
# btrfs-progs. It is idempotent (a no-op once the filesystem fills the
# partition).
if command -v btrfs >/dev/null 2>&1; then
	btrfs filesystem resize max "\$ROOT" 2>/dev/null || true
fi

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
chmod 0700 /config/combustion/script
sync
umount /config
losetup -d "$CONFIG_LOOP"
trap - EXIT

# Refresh the kernel partition table to the freshly written GPT before
# efibootmgr resolves partition 2, and create an explicit NVRAM entry.
partx -u "$DISK" 2>/dev/null || true
blockdev --rereadpt "$DISK" 2>/dev/null || true

# Grow the image's root filesystem to fill the (larger) root partition before
# the first boot. Filling the disk with the Combustion partition suppresses the
# image's own growroot / kiwi-repart first-boot resize, so grow it here or the
# root stays at its small image size (a few GiB) inside a large partition.
# btrfs resize needs a mounted path, so mount the partition briefly; the
# Combustion script also grows it as a fallback if this cannot run.
ROOT_PART=$DISK
case "$DISK" in
	/dev/nvme*|/dev/mmcblk*|/dev/loop*) ROOT_PART="${DISK}p3" ;;
	*) ROOT_PART="${DISK}3" ;;
esac
if [[ -b "$ROOT_PART" ]] && command -v btrfs >/dev/null 2>&1; then
	modprobe btrfs 2>/dev/null || true
	mkdir -p /mnt/root
	if mount -o rw "$ROOT_PART" /mnt/root 2>/dev/null; then
		if btrfs filesystem resize max /mnt/root; then
			printf 'Grew the root filesystem on %s to fill the partition\n' "$ROOT_PART"
		else
			printf 'WARNING: could not grow the root filesystem on %s\n' "$ROOT_PART" >&2
		fi
		umount /mnt/root 2>/dev/null || true
	else
		printf 'WARNING: could not mount %s to grow the root filesystem\n' "$ROOT_PART" >&2
	fi
else
	printf 'WARNING: btrfs is unavailable; the root filesystem was not grown here\n' >&2
fi

if [[ -d /sys/firmware/efi ]]; then
	command -v efibootmgr >/dev/null 2>&1 || fail 'UEFI boot detected but efibootmgr is not staged'
	efibootmgr -c -d "$DISK" -p 2 -L 'vps2img-kexec' -l '\EFI\BOOT\BOOTX64.EFI' || \
		fail 'efibootmgr could not create the vps2img-kexec boot entry'
	efibootmgr -v || fail 'efibootmgr could not read the new boot entry'
else
	printf '%s\n' 'UEFI runtime unavailable; relying on the EFI fallback path or BIOS boot code.'
fi
	flush_disk
	printf '%s\n' 'Raw image written. Rebooting into the new system.'
reboot -f
DEPLOY
	chmod 0755 "$STAGE/deploy"
}

build_initramfs() {
	case "$RAMDISK_SOURCE" in
		host) build_initramfs_host ;;
		debian) build_initramfs_debian ;;
		*) die "invalid --ramdisk-source: $RAMDISK_SOURCE (use host or debian)" ;;
	esac
}

ramdisk_source_description() {
	if [[ "$RAMDISK_SOURCE" == debian ]]; then
		printf 'Debian installer (d-i) components (%s %s/%s, assembled without the host package manager)' \
			"$DI_MIRROR" "$DI_SUITE" "$DI_ARCH"
	else
		printf 'host system tools (busybox + staged host binaries and libraries)'
	fi
}

di_url() {
	printf '%s/dists/%s/%s\n' "$DI_MIRROR" "$DI_SUITE" "$1"
}

# fetch_debian_index downloads and caches a Debian Packages index: the ordinary
# .deb archive or the debian-installer .udeb archive for the target suite/arch.
fetch_debian_index() {
	local dist=$1 rel destination url
	case "$dist" in
		deb) rel="main/binary-$DI_ARCH/Packages.gz"; destination=$DI_DEB_INDEX ;;
		udeb) rel="main/debian-installer/binary-$DI_ARCH/Packages.gz"; destination=$DI_UDEB_INDEX ;;
		*) die "internal error: unknown Debian index '$dist'" ;;
	esac
	[[ -s "$destination" ]] && return 0
	url=$(di_url "$rel")
	printf 'Fetching Debian %s index: %s\n' "$dist" "$url"
	download_file "$url" "$destination.download"
	gzip -dc "$destination.download" > "$destination"
	rm -f "$destination.download"
	[[ -s "$destination" ]] || die "the Debian $dist index is empty: $url"
}

# di_parse_index turns a Packages index into the lookup tables used by the
# resolver: package name -> Filename and package name -> Depends/Pre-Depends.
# Debian field continuation lines (which start with a space) are ignored, which
# is safe because in practice only Description/Tag wrap.
di_parse_index() {
	local dist=$1 file=$2 name filename dependencies key
	[[ -n "${DI_INDEX_PARSED[$dist]:-}" ]] && return 0
	DI_INDEX_PARSED[$dist]=1
	while IFS=$'\t' read -r name filename dependencies; do
		[[ -n "$name" && -n "$filename" ]] || continue
		key=$dist/$name
		DI_PKG_FILE[$key]=$filename
		DI_PKG_DEP[$key]=$dependencies
		DI_PKG_DISTS[$name]="${DI_PKG_DISTS[$name]:-}${DI_PKG_DISTS[$name]:+ }$dist"
	done < <(awk -v dist="$dist" '
		/^Package: /{ name=substr($0,10) }
		/^Filename: /{ filename=substr($0,11) }
		/^Depends: /{ dependencies=dependencies (dependencies?" ":"") substr($0,10) }
		/^Pre-Depends: /{ dependencies=dependencies (dependencies?" ":"") substr($0,13) }
		/^$/{ if(name!=""){ print name "\t" filename "\t" dependencies } name="";filename="";dependencies="" }
		END{ if(name!=""){ print name "\t" filename "\t" dependencies } }
	' "$file")
}

load_debian_indexes() {
	fetch_debian_index deb
	fetch_debian_index udeb
	di_parse_index deb "$DI_DEB_INDEX"
	di_parse_index udeb "$DI_UDEB_INDEX"
}

# resolve_debian_packages walks the dependency graph of the requested packages,
# following shared-library dependencies (names starting with "lib") recursively
# so the assembled initramfs has a complete runtime closure.  The result is the
# global RESOLVED_DEBS array of "dist filename" entries.
resolve_debian_packages() {
	local -a queue=("$@")
	local name key dist dependency depspec old_ifs
	local -A resolved=()
	RESOLVED_DEBS=()
	while ((${#queue[@]})); do
		name=${queue[0]}
		queue=("${queue[@]:1}")
		[[ -n "$name" ]] || continue
		[[ -n "${resolved[$name]:-}" ]] && continue
		resolved[$name]=1
		if [[ -z "${DI_PKG_DISTS[$name]:-}" ]]; then
			warn "Debian package not found in $DI_SUITE/$DI_ARCH: $name"
			continue
		fi
		for dist in ${DI_PKG_DISTS[$name]}; do
			key=$dist/$name
			RESOLVED_DEBS+=("$dist ${DI_PKG_FILE[$key]}")
			depspec=${DI_PKG_DEP[$key]:-}
			old_ifs=$IFS
			IFS=,
			for dependency in $depspec; do
				dependency=${dependency%%|*}
				dependency=${dependency#"${dependency%%[![:space:]]*}"}
				dependency=${dependency%% *}
				dependency=${dependency%%:*}
				[[ -n "$dependency" ]] || continue
				[[ "$dependency" == lib* ]] || continue
				queue+=("$dependency")
			done
			IFS=$old_ifs
		done
	done
}

# extract_package_into unpacks the data.tar member of a .deb/.udeb into the tree
# rooted at $2.  Only the archive tooling (ar + tar with the right decompressor)
# is needed, never the host package manager.
extract_package_into() {
	local archive=$1 destination=$2 member
	member=$(ar t "$archive" | awk '/^data\.tar/{ print; exit }')
	[[ -n "$member" ]] || die "no data.tar member in $archive"
	case "$member" in
		*.tar.xz) ar p "$archive" "$member" | tar --no-same-owner -xJ -C "$destination" ;;
		*.tar.zst) ar p "$archive" "$member" | tar --no-same-owner --zstd -x -C "$destination" ;;
		*.tar.gz) ar p "$archive" "$member" | tar --no-same-owner -xz -C "$destination" ;;
		*.tar.bz2) ar p "$archive" "$member" | tar --no-same-owner -xj -C "$destination" ;;
		*.tar) ar p "$archive" "$member" | tar --no-same-owner -x -C "$destination" ;;
		*) die "unknown data.tar compression in $archive ($member)" ;;
	esac
}

stage_debian_packages() {
	local entry dist filename destination url
	for entry in "${RESOLVED_DEBS[@]}"; do
		dist=${entry%% *}
		filename=${entry#* }
		destination="$WORKDIR/debs/$(basename "$filename")"
		if [[ ! -s "$destination" ]]; then
			url="$DI_MIRROR/$filename"
			printf 'Downloading Debian %s package: %s\n' "$dist" "$url"
			download_file "$url" "$destination"
		fi
		extract_package_into "$destination" "$STAGE"
	done
}

unpack_debian_initrd() {
	local archive=$WORKDIR/debian-initrd.gz url
	if [[ ! -s "$archive" ]]; then
		url=$(di_url "main/installer-$DI_ARCH/current/images/netboot/debian-installer/$DI_ARCH/initrd.gz")
		printf 'Fetching Debian installer initrd: %s\n' "$url"
		download_file "$url" "$archive"
	fi
	rm -rf "$STAGE"
	mkdir -p "$STAGE"
	( cd "$STAGE" && gzip -dc "$archive" | cpio -i -d -m --no-absolute-filenames ) || \
		die 'cannot unpack the Debian installer initrd'
}

# ensure_host_kexec makes a kexec binary available for the host-side kexec step.
# It prefers the host's own kexec and otherwise extracts kexec-tools (with its
# dependency closure, including kexec-tools' libxen* libraries) into $WORKDIR so
# no host package manager is involved.  The extracted library directories are
# added to LD_LIBRARY_PATH for the kexec calls.
ensure_host_kexec() {
	local entry dist filename destination kexec_path libdirs
	[[ -n "$KEXEC_BIN" ]] && return 0
	if KEXEC_BIN=$(command_path kexec); then
		return 0
	fi
	[[ "$RAMDISK_SOURCE" == debian ]] || die 'kexec is required on the host'
	printf '%s\n' 'kexec is not installed on the host; fetching Debian kexec-tools for the kexec step'
	mkdir -p "$WORKDIR/debs" "$WORKDIR/hostbin"
	load_debian_indexes
	resolve_debian_packages kexec-tools
	for entry in "${RESOLVED_DEBS[@]}"; do
		dist=${entry%% *}
		filename=${entry#* }
		destination="$WORKDIR/debs/$(basename "$filename")"
		if [[ ! -s "$destination" ]]; then
			printf 'Downloading Debian %s package: %s\n' "$dist" "$DI_MIRROR/$filename"
			download_file "$DI_MIRROR/$filename" "$destination"
		fi
		extract_package_into "$destination" "$WORKDIR/hostbin"
	done
	kexec_path=$(find "$WORKDIR/hostbin" -type f -name kexec -perm -u+x 2>/dev/null | head -n1)
	[[ -n "$kexec_path" ]] || die 'the Debian kexec-tools package did not provide a kexec binary'
	libdirs=$(find "$WORKDIR/hostbin" -type d -name '*-linux-gnu' 2>/dev/null | paste -sd: -)
	LD_LIBRARY_PATH="${libdirs}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	export LD_LIBRARY_PATH
	KEXEC_BIN=$kexec_path
	printf 'Using kexec binary: %s\n' "$KEXEC_BIN"
}

build_initramfs_debian() {
	local dropbear_path
	printf 'Ramdisk source: %s\n' "$(ramdisk_source_description)"
	rm -rf "$STAGE"
	mkdir -p "$WORKDIR/debs"
	unpack_debian_initrd
	load_debian_indexes
	# Base tools that turn the Debian installer initrd into the deploy ramdisk.
	# util-linux gives lsblk/findmnt/partx/blockdev/blkid; the separate mount
	# package gives losetup (Debian 13 moved it out of util-linux); coreutils
	# gives timeout/setsid/sync/sha256sum; gdisk gives sgdisk; efibootmgr gives
	# efibootmgr; iproute2 gives ip; kmod gives modprobe/modinfo; dropbear-bin
	# gives dropbear (SSH rescue); bash is the /init interpreter; zlib1g is the
	# one non-"lib"-named runtime dependency (dropbear and btrfs link it).
	# The udebs give sfdisk (fdisk-udeb), mke2fs (e2fsprogs-udeb) and btrfs
	# (btrfs-progs-udeb).  Shared-library dependencies are resolved recursively.
	resolve_debian_packages \
		util-linux coreutils mount bash libtinfo6 zlib1g gdisk efibootmgr \
		kexec-tools kmod iproute2 dropbear-bin \
		fdisk-udeb e2fsprogs-udeb btrfs-progs-udeb
	stage_debian_packages
	# Documentation and translations dominate the size of a full .deb
	# extraction and no deploy tool reads them, so drop them to keep the
	# initramfs small enough for kexec_file_load.
	rm -rf "$STAGE/usr/share/doc" "$STAGE/usr/share/man" "$STAGE/usr/share/info" \
		"$STAGE/usr/share/locale" "$STAGE/usr/share/bash-completion" \
		"$STAGE/usr/share/doc-base" "$STAGE/usr/share/gettext" \
		"$STAGE/usr/share/lintian" "$STAGE/usr/share/bug"
	# The Debian installer ships busybox at /usr/bin/busybox; /init expects it at
	# /bin/busybox.  The d-i busybox has no mdev applet, which /init tolerates.
	mkdir -p "$STAGE/bin"
	ln -sf /usr/bin/busybox "$STAGE/bin/busybox"
	# dropbear self-generates a host key at start when none is supplied, so no
	# host-side dropbearkey is needed in Debian mode.
	dropbear_path=$(find "$STAGE/usr/sbin" "$STAGE/usr/bin" "$STAGE/sbin" "$STAGE/bin" \
		-maxdepth 1 -type f -name dropbear 2>/dev/null | head -n1)
	if [[ -n "$dropbear_path" ]]; then
		DROPBEAR_BIN=${dropbear_path#"$STAGE"}
	else
		DROPBEAR_BIN=
		warn 'dropbear was not found in the Debian packages; SSH rescue will be unavailable'
	fi
	DROPBEAR_KEY=
	rm -f "$STAGE/init" "$STAGE/deploy"
	finalize_initramfs
}

build_initramfs_host() {
	local command_name command_file
	rm -rf "$STAGE"
	mkdir -p "$STAGE"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,proc,sys,dev,tmp,run,config,etc/dropbear,root/.ssh}

	# Static busybox provides the shell applets (sh, wget, dd, head, sha256sum,
	# ip, blockdev, setsid, ...) and keeps the initramfs small.
	cp -L "$(command_path busybox)" "$STAGE/bin/busybox"
	[[ -x "$STAGE/bin/busybox" ]] || die 'busybox is not executable'

	for command_name in bash blkid dd dropbear efibootmgr findmnt losetup lsblk mke2fs partx sfdisk sgdisk; do
		command_file=$(command_path "$command_name")
		[[ -n "$command_file" ]] || die "cannot stage command into the initramfs: $command_name"
		stage_binary_into "$STAGE" "$command_file"
	done
	# btrfs-progs grows the image's root filesystem to fill its partition; it is
	# optional so the deploy still works on a source without btrfs-progs (the
	# Combustion script grows the filesystem as a fallback).
	if command_file=$(command_path btrfs); then
		stage_binary_into "$STAGE" "$command_file"
	else
		warn 'btrfs is not installed on the source; the root filesystem will be grown by the target instead'
	fi
	DROPBEAR_BIN=$(command_path dropbear)
	DROPBEAR_KEY=
	finalize_initramfs
}

# finalize_initramfs adds the parts common to both ramdisk sources: the in-use
# kernel modules and firmware, the account files, the deploy scripts and the
# environment, then packs everything into a gzip cpio initramfs.
finalize_initramfs() {
	mkdir -p "$STAGE"/{proc,sys,dev,tmp,run,config,etc/dropbear,root/.ssh}

	# The kernel modules still come from the host's /lib/modules/$(uname -r):
	# kexec loads the RUNNING kernel, so ONLY modules built for that exact
	# kernel are valid.  This is the one unavoidable host dependency of the
	# Debian ramdisk source; it is not something the d-i components can replace.
	stage_kernel_modules
	stage_firmware

	# Minimal account/database files so dropbear can resolve root and exec a shell.
	printf 'root:x:0:0:root:/root:/bin/sh\n' > "$STAGE/etc/passwd"
	printf 'root:x:0:\n' > "$STAGE/etc/group"
	printf '/bin/sh\n/bin/bash\n' > "$STAGE/etc/shells"
	printf 'passwd: files\ngroup: files\n' > "$STAGE/etc/nsswitch.conf"

	# In host mode a throwaway dropbear host key is generated on the source host.
	# In Debian mode dropbear generates its own key at start (no host dropbearkey).
	if [[ "$RAMDISK_SOURCE" == host ]]; then
		if dropbearkey -t ed25519 -f "$STAGE/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1; then
			DROPBEAR_KEY=/etc/dropbear/dropbear_ed25519_host_key
		elif dropbearkey -t rsa -s 2048 -f "$STAGE/etc/dropbear/dropbear_rsa_host_key" >/dev/null 2>&1; then
			DROPBEAR_KEY=/etc/dropbear/dropbear_rsa_host_key
		else
			die 'dropbearkey could not generate a host key'
		fi
		chmod 600 "$STAGE/etc/dropbear/"* 2>/dev/null || true
	fi

	cp -aL "$SSH_KEY_FILE" "$STAGE/authorized_keys"
	cp -aL "$SSH_KEY_FILE" "$STAGE/root/.ssh/authorized_keys"
	chmod 600 "$STAGE/root/.ssh/authorized_keys"

	# embed mode carries the raw image; stream mode does not (the whole point).
	if [[ "$IMAGE_MODE" == embed ]]; then
		if [[ "$(stat -c %d "$RAW_FILE")" == "$(stat -c %d "$STAGE")" ]]; then
			ln -f "$RAW_FILE" "$STAGE/image.raw"
		else
			cp -a "$RAW_FILE" "$STAGE/image.raw"
		fi
	fi

	{
		printf 'DISK=%q\n' "$TARGET_DISK"
		printf 'IMAGE_MODE=%q\n' "$IMAGE_MODE"
		printf 'IMAGE_RAW_URL=%q\n' "$IMAGE_RAW_URL"
		printf 'IMAGE_SHA256=%q\n' "$IMAGE_SHA256"
		printf 'IMAGE_SIZE=%q\n' "$IMAGE_SIZE"
		printf 'DROPBEAR_BIN=%q\n' "$DROPBEAR_BIN"
		printf 'DROPBEAR_KEY=%q\n' "$DROPBEAR_KEY"
		printf 'TARGET_HOSTNAME=%q\n' "$TARGET_HOSTNAME"
		printf 'TARGET_INTERFACE=%q\n' "$TARGET_INTERFACE"
		printf 'TARGET_INTERFACE_NAMES=%q\n' "$TARGET_INTERFACE_NAMES"
		printf 'TARGET_MAC=%q\n' "$TARGET_MAC"
		printf 'TARGET_IPV4_CIDR=%q\n' "$TARGET_IPV4_CIDR"
		printf 'TARGET_GATEWAY=%q\n' "$TARGET_GATEWAY"
		printf 'TARGET_DNS=%q\n' "$TARGET_DNS"
		printf 'TARGET_USER=%q\n' "$TARGET_USER"
		printf 'TARGET_PASSWORD=%q\n' "$TARGET_PASSWORD"
		printf 'TARGET_NIC_DRIVERS=%q\n' "$TARGET_NIC_DRIVERS"
		printf 'TARGET_DISK_DRIVERS=%q\n' "$TARGET_DISK_DRIVERS"
		printf 'ROOT_SIZE_GIB=%q\n' "$ROOT_SIZE_GIB"
		printf 'CONFIG_SIZE_MIB=%q\n' "$CONFIG_SIZE_MIB"
	} > "$STAGE/deploy.env"

	write_init
	write_deploy
	/usr/bin/bash -n "$STAGE/init"
	/usr/bin/bash -n "$STAGE/deploy"

	printf 'Building initramfs: %s\n' "$INITRAMFS"
	( cd "$STAGE" && find . -print0 | cpio -0 -o -H newc 2>/dev/null ) | gzip -6 > "$INITRAMFS"
	[[ -s "$INITRAMFS" ]] || die 'the initramfs archive is empty'
	rm -rf "$STAGE"
}

# load_kexec_image loads the running kernel plus the generated initramfs into the
# kexec slot. Under UEFI Secure Boot the kernel is locked down and only
# kexec_file_load (-s) is permitted, and only for a kernel image the firmware
# already trusts -- the running, signed kernel that booted under Secure Boot.
# kexec_load (-c) is kept as a fallback for a host without lockdown, where the
# legacy syscall is still allowed.
load_kexec_image() {
	local command_line=$1
	printf 'Loading kernel with kexec_file_load (-s): %s\n' "$KEXEC_KERNEL"
	if "$KEXEC_BIN" -s -l "$KEXEC_KERNEL" --initrd="$INITRAMFS" --command-line="$command_line"; then
		KEXEC_METHOD=file
		return 0
	fi
	if (( KEXEC_LOCKDOWN )); then
		die 'kexec_file_load (-s) was rejected while lockdown is active; the running kernel was not accepted as a trusted image'
	fi
	printf '%s\n' 'kexec_file_load (-s) failed; falling back to kexec_load (-c)'
	"$KEXEC_BIN" -c -l "$KEXEC_KERNEL" --initrd="$INITRAMFS" --command-line="$command_line" || \
		die 'kexec could not load the kernel with either kexec_file_load (-s) or kexec_load (-c)'
	KEXEC_METHOD=legacy
}

# unload_kexec_image clears whatever load_kexec_image put in the kexec slot,
# preferring the syscall that actually loaded it.
unload_kexec_image() {
	if [[ "$KEXEC_METHOD" == legacy ]]; then
		"$KEXEC_BIN" -c -u 2>/dev/null || "$KEXEC_BIN" -u
	else
		"$KEXEC_BIN" -s -u 2>/dev/null || "$KEXEC_BIN" -u
	fi
}

run_kexec() {
	local command_line
	command_line="console=ttyS0,115200 console=tty0 panic=120 vps2img-kexec.disk=$TARGET_DISK"
	load_kexec_image "$command_line"
	printf '%s\n' 'Switching kernels with kexec -e; the old kernel and systemd are discarded now.'
	sync
	"$KEXEC_BIN" -e
}

parse_args() {
	EXECUTE=0
	STAGE_TEST=0
	while (($#)); do
		case $1 in
			--image-url) IMAGE_URL=${2:?missing value for --image-url}; shift 2 ;;
			--image-file) IMAGE_FILE=${2:?missing value for --image-file}; shift 2 ;;
			--image-raw-url) IMAGE_URL=${2:?missing value for --image-raw-url}; shift 2 ;;
			--sha256) IMAGE_SHA256=${2:?missing value for --sha256}; shift 2 ;;
			--image-size) IMAGE_SIZE=${2:?missing value for --image-size}; shift 2 ;;
			--disk) TARGET_DISK=${2:?missing value for --disk}; shift 2 ;;
			--hostname) TARGET_HOSTNAME=${2:?missing value for --hostname}; shift 2 ;;
			--interface) TARGET_INTERFACE=${2:?missing value for --interface}; shift 2 ;;
			--ipv4) TARGET_IPV4_CIDR=${2:?missing value for --ipv4}; shift 2 ;;
			--gateway) TARGET_GATEWAY=${2:?missing value for --gateway}; shift 2 ;;
			--dns) TARGET_DNS=${2:?missing value for --dns}; shift 2 ;;
			--user) TARGET_USER=${2:?missing value for --user}; shift 2 ;;
			--password) TARGET_PASSWORD=${2:?missing value for --password}; shift 2 ;;
			--ssh-key-file) SSH_KEY_FILE=${2:?missing value for --ssh-key-file}; shift 2 ;;
			--root-size-gib) ROOT_SIZE_GIB=${2:?missing value for --root-size-gib}; shift 2 ;;
			--config-size-mib) CONFIG_SIZE_MIB=${2:?missing value for --config-size-mib}; shift 2 ;;
			--kernel) KEXEC_KERNEL=${2:?missing value for --kernel}; shift 2 ;;
			--ramdisk-source) RAMDISK_SOURCE=${2:?missing value for --ramdisk-source}; shift 2 ;;
			--di-mirror) DI_MIRROR=${2:?missing value for --di-mirror}; shift 2 ;;
			--di-suite) DI_SUITE=${2:?missing value for --di-suite}; shift 2 ;;
			--di-arch) DI_ARCH=${2:?missing value for --di-arch}; shift 2 ;;
			--image-mode) IMAGE_MODE_REQUEST=${2:?missing value for --image-mode}; shift 2 ;;
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
	case "$RAMDISK_SOURCE" in
		host|debian) ;;
		*) die "invalid --ramdisk-source: $RAMDISK_SOURCE (use host or debian)" ;;
	esac
	resolve_image_mode
	check_dependencies
	check_kexec_support
	discover_source
	discover_configuration
	detect_kernel
	prepare_image
	print_plan

	if (( STAGE_TEST )); then
		ensure_host_kexec
		build_initramfs
		printf 'STAGE-TEST: initramfs is %s bytes\n' "$(stat -c '%s' "$INITRAMFS")"
		load_kexec_image "console=ttyS0,115200 console=tty0 panic=120 vps2img-kexec.disk=$TARGET_DISK"
		unload_kexec_image
		printf '%s\n' "STAGE-TEST: initramfs scripts syntax-checked and kexec load/unload succeeded (method=$KEXEC_METHOD); no kernel switch and no disk change."
		[[ "${VPS2IMG_KEXEC_KEEP_INITRAMFS:-0}" == 1 ]] || rm -f "$INITRAMFS"
		return 0
	fi

	if (( ! EXECUTE )); then
		printf '%s\n' 'DRY-RUN: no disk, mount, kexec, or reboot operation was performed.'
		return 0
	fi
	[[ "${VPS2IMG_KEXEC_CONFIRM:-}" == "WIPE:$TARGET_DISK" ]] || \
		die "set VPS2IMG_KEXEC_CONFIRM=WIPE:$TARGET_DISK to allow the destructive operation"
	[[ "$SOURCE_DISK" == "$TARGET_DISK" ]] || warn 'target is not the current root disk; verify it before continuing'
	ensure_host_kexec
	build_initramfs
	run_kexec
}

main "$@"
