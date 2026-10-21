
discover_configuration() {
	(#@INCLUDE@expand) src/assets/discover-network.sh
	(#@INCLUDE@expand) src/assets/validate-target.sh
}

check_target_mounts() {
	local node type mount_source
	while read -r node type; do
		[[ "$type" == part ]] || continue
		mount_source=$(findmnt -rn -S "$node" || true)
		[[ -z "$mount_source" ]] || die "target partition is mounted: $node ($mount_source)"
	done < <(lsblk -nrpo NAME,TYPE "$TARGET_DISK")
}

print_plan() {
	local size_bytes disk_bytes model
	size_bytes=$(stat -c '%s' "$RAW_FILE")
	disk_bytes=$(blockdev --getsize64 "$TARGET_DISK")
	model=$(lsblk -dnro MODEL "$TARGET_DISK" | sed 's/[[:space:]]*$//')
	printf '%s\n' '=== VPS2IMG_PIVOT PLAN ==='
	(#@INCLUDE@expand) src/assets/plan-base.sh
	printf 'raw image:       %s (%s bytes)\n' "$RAW_FILE" "$size_bytes"
	if [[ "$VERIFY_IMAGE" == 1 ]]; then
		printf 'image sha256:    %s (verification enabled)\n' "$IMAGE_SHA256"
	else
		printf '%s\n' 'image sha256:    verification disabled (--no-verify-image)'
	fi
	(#@INCLUDE@expand) src/assets/plan-target.sh
	printf 'login user:      %s\n' "$TARGET_USER"
	(#@INCLUDE@expand) src/assets/plan-disk.sh
	printf 'raw partition table:\n'
	sfdisk --dump "$RAW_FILE" 2>/dev/null || warn 'sfdisk could not print the raw image partition table'
	if [[ "$SOURCE_DISK" == "$TARGET_DISK" ]]; then
		printf '%s\n' 'The target is the current system disk.'
	else
		printf '%s\n' 'The target is different from the current system disk.'
	fi
}

check_dependencies() {
	local command_name
	for command_name in awk blockdev cp dd findmnt lsblk mount readlink rm sha256sum sfdisk sgdisk stat sync tr umount; do
		need_command "$command_name"
	done
	for command_name in hostname ip mountpoint paste; do
		need_command "$command_name"
	done
}

stage_bootstrap() {
	local command_name command_file raw_size bootstrap_size
	raw_size=$(stat -c '%s' "$RAW_FILE")
	bootstrap_size=$((raw_size + 1073741824))
	if mountpoint -q "$BOOTSTRAP" 2>/dev/null; then
		umount -Rl "$BOOTSTRAP" || die "cannot clean old bootstrap: $BOOTSTRAP"
	fi
	rm -rf "$BOOTSTRAP"
	mkdir -p "$BOOTSTRAP"
	mount -t tmpfs -o "size=${bootstrap_size},mode=755" tmpfs "$BOOTSTRAP"
	mkdir -p "$BOOTSTRAP"/{dev,proc,sys,run,etc}

	for command_name in bash mount umount mountpoint fsfreeze sync mkdir rm cp cat grep awk sed tr cut \
		dd findmnt lsblk sha256sum sfdisk sgdisk blockdev stat losetup partx blkid \
		lvchange vgchange chroot pivot_root reboot mkfs.ext4 chmod \
		sleep; do
		command_file=$(command_path "$command_name")
		[[ -n "$command_file" ]] || die "cannot stage command: $command_name"
		stage_binary "$BOOTSTRAP" "$command_file"
	done
	if command_file=$(command_path efibootmgr); then
		stage_binary "$BOOTSTRAP" "$command_file"
	fi
	# btrfs-progs is deliberately not staged: the RAM deployer cannot grow the
	# new image's btrfs (the old kernel still holds the former root's frozen
	# superblock), so the target's Combustion script does it on first boot.
	# Convenience tools for the rescue shell. None of them is needed to deploy,
	# so a source without them only makes the dropbear/console session poorer.
	for command_name in ls ps tail head less more vi df du free hostname ip \
		ping ss nc tcpdump find sort uniq wc; do
		if command_file=$(command_path "$command_name"); then
			stage_binary "$BOOTSTRAP" "$command_file"
		else
			warn "rescue tool is missing on the source: $command_name"
		fi
	done
	# busybox backs the remaining applets with one small binary. Its applet
	# symlinks only fill paths that no staged real binary already owns, so the
	# whitelisted tools above keep precedence.
	if command_file=$(command_path busybox); then
		stage_binary "$BOOTSTRAP" "$command_file"
		mkdir -p "$BOOTSTRAP/bin"
		if [[ "$command_file" != /bin/busybox ]]; then
			ln -sf "../${command_file#/}" "$BOOTSTRAP/bin/busybox"
		fi
		# Never let an applet shadow a staged real binary: the deployer needs
		# the host's real mount/umount/sgdisk/dd semantics, not busybox's.
		while read -r applet; do
			applet=${applet##*/}
			[[ -n "$applet" ]] || continue
			for dir in bin sbin usr/bin usr/sbin; do
				[[ -e "$BOOTSTRAP/$dir/$applet" || -L "$BOOTSTRAP/$dir/$applet" ]] && continue 2
			done
			ln -sf busybox "$BOOTSTRAP/bin/$applet"
		done < <("$command_file" --list 2>/dev/null)
	else
		warn 'busybox is not installed on the source; the rescue shell only has the staged tools'
	fi
	# Optional rescue SSH for the RAM bootstrap: after pivot_root the old sshd
	# (and the operator's original session) is terminated and a dropbear takes
	# over port 22.  Best-effort, so an image deploy still works on a source
	# without the dropbear package.
	DROPBEAR_BIN=
	if command_file=$(command_path dropbear); then
		DROPBEAR_BIN=$command_file
		stage_binary "$BOOTSTRAP" "$command_file"
		command_file=$(command_path dropbearkey)
		[[ -n "$command_file" ]] || die 'dropbear is installed but dropbearkey is missing'
		stage_binary "$BOOTSTRAP" "$command_file"
		mkdir -p "$BOOTSTRAP/etc/dropbear" "$BOOTSTRAP/root/.ssh" "$BOOTSTRAP/bin"
		dropbearkey -t ed25519 -f "$BOOTSTRAP/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1 || \
			die 'dropbearkey could not generate a rescue host key'
		chmod 600 "$BOOTSTRAP/etc/dropbear/dropbear_ed25519_host_key"
		cp -aL "$SSH_KEY_FILE" "$BOOTSTRAP/root/.ssh/authorized_keys"
		chmod 600 "$BOOTSTRAP/root/.ssh/authorized_keys"
		# Minimal account files and a shell so dropbear can resolve root and
		# exec /bin/sh (a symlink to the staged bash).
		printf 'root:x:0:0:root:/root:/bin/sh\n' > "$BOOTSTRAP/etc/passwd"
		printf 'root:x:0:\n' > "$BOOTSTRAP/etc/group"
		printf '/bin/sh\n' > "$BOOTSTRAP/etc/shells"
		printf 'passwd: files\ngroup: files\n' > "$BOOTSTRAP/etc/nsswitch.conf"
		ln -sf "$(command_path bash)" "$BOOTSTRAP/bin/sh"
	fi
	cp -a "$RAW_FILE" "$BOOTSTRAP/run/image.raw"
	cp -aL "$SSH_KEY_FILE" "$BOOTSTRAP/run/authorized_keys"
	cat > "$BOOTSTRAP/run/deploy.env" <<EOF
TARGET_HOSTNAME=$(printf '%q' "$TARGET_HOSTNAME")
TARGET_INTERFACE=$(printf '%q' "$TARGET_INTERFACE")
TARGET_INTERFACE_NAMES='$TARGET_INTERFACE_NAMES'
TARGET_MAC=$(printf '%q' "$TARGET_MAC")
TARGET_IPV4_CIDR=$(printf '%q' "$TARGET_IPV4_CIDR")
TARGET_GATEWAY=$(printf '%q' "$TARGET_GATEWAY")
TARGET_DNS=$(printf '%q' "$TARGET_DNS")
TARGET_USER=$(printf '%q' "$TARGET_USER")
TARGET_PASSWORD=$(printf '%q' "$TARGET_PASSWORD")
ROOT_SIZE_GIB=$(printf '%q' "$ROOT_SIZE_GIB")
CONFIG_SIZE_MIB=$(printf '%q' "$CONFIG_SIZE_MIB")
REBOOT_DELAY=$(printf '%q' "$REBOOT_DELAY")
DROPBEAR_BIN=$(printf '%q' "$DROPBEAR_BIN")
EOF
	cat > "$BOOTSTRAP/run/deploy" <<'INNER'
#!/usr/bin/env bash
set -Eeuo pipefail

DISK=${1:?target disk is required}
RAW=/run/image.raw
. /run/deploy.env

AUTHORIZED_KEYS=$(cat /run/authorized_keys)

fail() {
	printf 'FATAL: %s\n' "$*" >&2
	exit 1
}

flush_disk() {
	sync
	blockdev --flushbufs "$DISK" || fail "cannot flush pending writes for $DISK"
}

start_dropbear() {
	local attempt key=
	[[ -n "${DROPBEAR_BIN:-}" && -x "$DROPBEAR_BIN" ]] || {
		printf '%s\n' 'WARNING: dropbear is unavailable; SSH rescue cannot start.' >&2
		return 0
	}
	if [[ -r /etc/dropbear/dropbear_ed25519_host_key ]]; then
		key=/etc/dropbear/dropbear_ed25519_host_key
	fi
	# The old sshd's listening socket may linger for a moment after it is
	# terminated, so retry the bind before giving up.
	for attempt in 1 2 3 4 5 6 7 8 9 10; do
		if [[ -n "$key" ]]; then
			"$DROPBEAR_BIN" -s -r "$key" -p 22 -P /run/dropbear.pid >/dev/null 2>&1 && return 0
		else
			"$DROPBEAR_BIN" -s -p 22 -P /run/dropbear.pid >/dev/null 2>&1 && return 0
		fi
		sleep 1
	done
	printf '%s\n' 'WARNING: dropbear failed to bind port 22.' >&2
}

# The RAM bootstrap inherits the operator's SSH session from the old system, and
# the old sshd keeps running after pivot_root (the old init is only frozen, not
# killed).  Two problems follow: the port-22 socket is held by the old sshd, and
# that session's interactive shell plus the old systemd keep writing the old
# root, which lives on the very disk being overwritten.  Kill the old sshd, but
# first detach our own stdio to the console and ignore SIGHUP: killing the
# session's sshd closes its pty, and without this the deployer would be hung up
# with it.
detach_and_takeover_console() {
	trap '' HUP
	for tty in /dev/console /dev/ttyS0 /dev/tty0; do
		[[ -e "$tty" ]] || continue
		exec <"$tty" >"$tty" 2>&1
		break
	done
}

kill_old_sshd() {
	local proc pid comm
	for proc in /proc/[0-9]*; do
		pid=${proc##*/}
		[[ -r "$proc/comm" ]] || continue
		comm=$(<"$proc/comm")
		[[ "$comm" == sshd ]] || continue
		kill -TERM "$pid" 2>/dev/null || true
	done
}

rescue() {
	local tty shell
	printf '%s\n' 'RESCUE: automatic deploy did not finish; staying alive.' >&2
	printf '%s\n' 'RESCUE: SSH (dropbear, root pubkey) is available on port 22.' >&2
	printf '%s\n' 'RESCUE: a console shell is attached below as well.' >&2
	shell=/bin/sh
	[[ -x /bin/bash ]] && shell=/bin/bash
	for tty in /dev/tty0 /dev/ttyS0; do
		[[ -e "$tty" ]] || continue
		"$shell" -i <"$tty" >"$tty" 2>&1 &
	done
	while :; do
		if [[ -f /run/dropbear.pid ]] && kill -0 "$(< /run/dropbear.pid)" 2>/dev/null; then
			:
		else
			start_dropbear
		fi
		sleep 30
	done
}

printf '%s\n' '=== VPS2IMG_PIVOT RAM DEPLOYMENT ==='
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fail "not a whole disk: $DISK"
[[ -s "$RAW" ]] || fail 'raw image is missing from the RAM bootstrap'
# On any later failure keep the machine alive instead of exitting into a frozen
# old init: enter rescue(), which restarts dropbear (if it was staged) and
# attaches console shells.
trap 'printf "%s\n" "vps2img-pivot deployer exiting rc=$?" >&2; rescue' EXIT
# Take over from the old system before anything destroys the target disk: move
# our stdio off the dying SSH session now.  The old sshd itself is terminated
# only after PID1 is frozen below, so a still-running systemd cannot respawn it
# on port 22 before the rescue dropbear binds.
if [[ -n "${DROPBEAR_BIN:-}" ]]; then
	detach_and_takeover_console
fi
flush_disk

# Stop writes from the old LVM-backed root before pivoting away from it.
for volume in /dev/mapper/*; do
	[[ -b "$volume" ]] || continue
	case "$volume" in
		*/pve-swap|*/pve-data|*/pve-data_tdata|*/pve-data_tmeta) lvchange -an "$volume" 2>/dev/null || true ;;
	esac
done
flush_disk
# pivot_root does not terminate the old init system. Freeze PID 1 and the
# old logging, device, PVE and cluster services, otherwise old PVE/Btrfs dirty
# pages can be written back after dd and corrupt the new raw image. Keep the
# SSH/bash processes alive so the RAM deployer itself cannot be stopped by a
# name collision. watchdog-mux is deliberately NOT frozen: it owns
# /dev/watchdog and is the only process feeding the hardware watchdog, so
# stopping it would let the (often short) watchdog timer reset the machine
# in the middle of the write.
kill -STOP 1 2>/dev/null || true
for proc in /proc/[0-9]*; do
	pid=${proc##*/}
	[[ -r "$proc/comm" ]] || continue
	comm=$(<"$proc/comm")
	case "$comm" in
		systemd-journal|systemd-udevd|systemd-logind|\
			pveproxy|pvedaemon|pvestatd|pve-cluster|pve-firewall|pvescheduler|\
			pmxcfs|qmeventd|corosync)
			kill -STOP "$pid" 2>/dev/null || true
			;;
	esac
done
printf '%s\n' 'Old userspace frozen; continuing with target disk replacement.'

# PID1 is frozen now, so the old sshd cannot be respawned: terminate it and take
# over port 22 with the rescue dropbear.  Without a staged dropbear the old sshd
# (and the operator's original session) is deliberately left running.
if [[ -n "${DROPBEAR_BIN:-}" ]]; then
	kill_old_sshd
	start_dropbear
fi

# The old root is still mounted below /oldroot after pivot_root. Before the
# disk is touched, stop the two things that can still reach it after dd:
#
# 1. btrfs async discard. The old root is mounted discard=async and its
#    background discard workqueue TRIMs free extents. On a zvol or SSD a TRIM
#    zeroes the addressed sectors, so discarding the former root's free space
#    also zeroes whatever the freshly written image now stores there,
#    corrupting image files (observed as btrfs csum failures). Freezing the
#    filesystem does not stop this workqueue. mount -o remount,ro fails EBUSY
#    on the busy root, but a remount that only changes the discard option is
#    accepted, so nodiscard is applied here while the device is still writable.
# 2. The former root's own writeback. It is flushed and then frozen. btrfs
#    holds its transaction commit while frozen, so dirty pages and metadata
#    cannot be written back over the new data. The device must still be
#    writable when fsfreeze runs (it flushes as part of freezing), so the
#    read-only switch happens afterwards as a second line of defence.
#
# mount -o remount,ro is not attempted: it fails EBUSY while the old root is
# busy and would leave writeback pending.
if mount -o remount,nodiscard /oldroot 2>/dev/null; then
	printf '%s\n' 'Former root async discard disabled; it can no longer zero new data.'
else
	printf '%s\n' 'WARNING: could not disable async discard on the former root.' >&2
fi
flush_disk
if ! command -v fsfreeze >/dev/null 2>&1; then
	printf '%s\n' 'WARNING: fsfreeze is unavailable; the new image may be corrupted by former root writeback.' >&2
elif ! mountpoint -q /oldroot 2>/dev/null; then
	fail '/oldroot is not a mount point; cannot freeze the former root'
elif fsfreeze --freeze /oldroot; then
	printf '%s\n' 'Former root filesystem frozen; writeback is disabled.'
else
	fail 'cannot freeze the former root; refusing to overwrite the target disk'
fi
if [[ -n "${VPS2IMG_PIVOT_ROOT_SOURCE:-}" && -b "$VPS2IMG_PIVOT_ROOT_SOURCE" ]]; then
	blockdev --setro "$VPS2IMG_PIVOT_ROOT_SOURCE" || \
		printf '%s\n' "WARNING: cannot make old root read-only: $VPS2IMG_PIVOT_ROOT_SOURCE" >&2
fi
umount -Rl /oldroot || fail 'cannot detach the former target root'

for node in $(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" { print $1 }'); do
	[[ -z "$(findmnt -rn -S "$node" || true)" ]] || fail "target partition is still mounted: $node"
done

printf 'Writing %s to %s\n' "$RAW" "$DISK"
dd if="$RAW" of="$DISK" bs=16M conv=fsync status=progress
sync
