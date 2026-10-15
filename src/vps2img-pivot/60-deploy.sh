
discover_configuration() {
	local nameserver bridge_member altname source_interface
	[[ -n "$TARGET_HOSTNAME" ]] || TARGET_HOSTNAME=$(hostname -s)
	[[ -n "$TARGET_INTERFACE" ]] || TARGET_INTERFACE=$(ip -4 route show default | awk 'NR == 1 { print $5; exit }')
	[[ -n "$TARGET_INTERFACE" ]] || die 'cannot determine the default network interface; set --interface'
	# The source address and default route live on the interface that carries
	# them (a bridge such as vmbrX), not on its physical member. Remember it
	# before the member mapping below and use it to discover IPv4/gateway.
	source_interface=$TARGET_INTERFACE
	# A PVE host's vmbrX is not a deployable interface. Resolve its physical
	# bridge member first, then preserve the member name and all kernel altnames.
	if [[ "$TARGET_INTERFACE" == vmbr* ]]; then
		bridge_member=$(ip -o link show master "$TARGET_INTERFACE" | awk -F': |@' 'NR == 1 { print $2; exit }')
		if [[ -n "$bridge_member" ]]; then
			warn "mapping source bridge $TARGET_INTERFACE to target interface $bridge_member"
			TARGET_INTERFACE=$bridge_member
		else
			warn "source bridge $TARGET_INTERFACE has no visible member; target will use fallback discovery"
		fi
	fi
	[[ -n "$TARGET_INTERFACE_NAMES" ]] || TARGET_INTERFACE_NAMES=$TARGET_INTERFACE
	while read -r altname; do
		[[ -n "$altname" ]] || continue
		case ",$TARGET_INTERFACE_NAMES," in
			*,"$altname",*) ;;
			*) TARGET_INTERFACE_NAMES="$TARGET_INTERFACE_NAMES,$altname" ;;
		esac
	done < <(ip -o link show dev "$TARGET_INTERFACE" | awk '{ for (i = 1; i <= NF; i++) if ($i == "altname") { name = $(i + 1); sub(/\\$/, "", name); print name } }')
	if [[ -z "$TARGET_MAC" ]]; then
		[[ -r "/sys/class/net/$TARGET_INTERFACE/address" ]] || die "cannot determine MAC address for $TARGET_INTERFACE"
		TARGET_MAC=$(cat "/sys/class/net/$TARGET_INTERFACE/address")
	fi
	TARGET_MAC=$(printf '%s' "$TARGET_MAC" | tr '[:upper:]' '[:lower:]')
	[[ -n "$TARGET_IPV4_CIDR" ]] || \
		TARGET_IPV4_CIDR=$(ip -4 -o addr show dev "$TARGET_INTERFACE" scope global | awk 'NR == 1 { print $4; exit }')
	[[ -n "$TARGET_IPV4_CIDR" ]] || \
		TARGET_IPV4_CIDR=$(ip -4 -o addr show dev "$source_interface" scope global | awk 'NR == 1 { print $4; exit }')
	[[ -n "$TARGET_IPV4_CIDR" ]] || die 'cannot determine the current IPv4 address; set --ipv4'
	[[ -n "$TARGET_GATEWAY" ]] || \
		TARGET_GATEWAY=$(ip -4 route show default dev "$TARGET_INTERFACE" | awk 'NR == 1 { print $3; exit }')
	[[ -n "$TARGET_GATEWAY" ]] || \
		TARGET_GATEWAY=$(ip -4 route show default dev "$source_interface" | awk 'NR == 1 { print $3; exit }')
	[[ -n "$TARGET_GATEWAY" ]] || \
		TARGET_GATEWAY=$(ip -4 route show default | awk 'NR == 1 { print $3; exit }')
	[[ -n "$TARGET_GATEWAY" ]] || die 'cannot determine the default gateway; set --gateway'
	if [[ -z "$TARGET_DNS" ]]; then
		nameserver=$(awk '/^nameserver[[:space:]]+/ { print $2 }' /etc/resolv.conf | paste -sd ';' -)
		TARGET_DNS=$nameserver
	fi
	TARGET_DNS=${TARGET_DNS//,/;}
	TARGET_DNS=${TARGET_DNS// /;}
	[[ "$TARGET_DNS" == '' || "$TARGET_DNS" == *';' ]] || TARGET_DNS+=';'

	[[ "$TARGET_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || \
		die "invalid target hostname: $TARGET_HOSTNAME"
	[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || \
		die "invalid target user: $TARGET_USER"
	[[ "$TARGET_PASSWORD" != *$'\n'* && "$TARGET_PASSWORD" != *$'\r'* ]] || \
		die 'the target password may not contain a newline'
	[[ "$TARGET_INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || \
		die "invalid target interface: $TARGET_INTERFACE"
	[[ "$TARGET_INTERFACE_NAMES" =~ ^[A-Za-z0-9_.:-]+(,[A-Za-z0-9_.:-]+)*$ ]] || \
		die "invalid target interface names: $TARGET_INTERFACE_NAMES"
	[[ "$TARGET_MAC" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]] || \
		die "invalid target MAC address: $TARGET_MAC"
	[[ "$TARGET_IPV4_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || \
		die "invalid target IPv4 CIDR: $TARGET_IPV4_CIDR"
	[[ "$TARGET_GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || \
		die "invalid target gateway: $TARGET_GATEWAY"
	[[ "$ROOT_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] || die "invalid root size: $ROOT_SIZE_GIB GiB"
	[[ "$CONFIG_SIZE_MIB" =~ ^[1-9][0-9]*$ ]] || die "invalid config size: $CONFIG_SIZE_MIB MiB"
	[[ -s "$SSH_KEY_FILE" ]] || die "SSH authorized_keys file is missing or empty: $SSH_KEY_FILE"
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
	printf 'source root:    %s (%s)\n' "$ROOT_SOURCE" "$(findmnt -nro FSTYPE /)"
	printf 'source disk:    %s\n' "$SOURCE_DISK"
	printf 'target disk:    %s (%s bytes, %s)\n' "$TARGET_DISK" "$disk_bytes" "${model:-unknown model}"
	printf 'raw image:      %s (%s bytes)\n' "$RAW_FILE" "$size_bytes"
	printf 'target hostname: %s\n' "$TARGET_HOSTNAME"
	printf 'target network:  %s (%s) names=%s %s via %s DNS %s\n' "$TARGET_INTERFACE" "$TARGET_MAC" "$TARGET_INTERFACE_NAMES" "$TARGET_IPV4_CIDR" "$TARGET_GATEWAY" "${TARGET_DNS:-none}"
	printf 'login user:      %s\n' "$TARGET_USER"
	printf 'root/config:     %s GiB Btrfs / Combustion to end of disk (min %s MiB)\n' "$ROOT_SIZE_GIB" "$CONFIG_SIZE_MIB"
	printf 'SSH keys:        %s\n' "$SSH_KEY_FILE"
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

stage_binary() {
	local source=$1 real dependency dependency_real
	real=$(readlink -f "$source")
	[[ -x "$real" ]] || die "cannot stage executable: $source"
	mkdir -p "$BOOTSTRAP$(dirname "$source")" "$BOOTSTRAP$(dirname "$real")"
	# Resolve Debian alternatives/symlink entry points inside the bootstrap;
	# copying the absolute symlink alone would point back at the old root.
	cp -aL "$source" "$BOOTSTRAP$source"
	cp -a "$real" "$BOOTSTRAP$real"
	while read -r dependency; do
		[[ -z "$dependency" || "$dependency" == linux-vdso* ]] && continue
		[[ -e "$dependency" || -L "$dependency" ]] || continue
		mkdir -p "$BOOTSTRAP$(dirname "$dependency")"
		cp -aL "$dependency" "$BOOTSTRAP$dependency"
		dependency_real=$(readlink -f "$dependency")
		if [[ -e "$dependency_real" ]]; then
			mkdir -p "$BOOTSTRAP$(dirname "$dependency_real")"
			cp -a "$dependency_real" "$BOOTSTRAP$dependency_real"
		fi
	done < <(ldd "$real" 2>/dev/null | awk '/=> \/[^ ]+/ { print $3 } /^[[:space:]]*\/[^ ]+/ { print $1 }')
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
		stage_binary "$command_file"
	done
	if command_file=$(command_path efibootmgr); then
		stage_binary "$command_file"
	fi
	# Optional rescue SSH for the RAM bootstrap: after pivot_root the old sshd
	# (and the operator's original session) is terminated and a dropbear takes
	# over port 22.  Best-effort, so an image deploy still works on a source
	# without the dropbear package.
	DROPBEAR_BIN=
	if command_file=$(command_path dropbear); then
		DROPBEAR_BIN=$command_file
		stage_binary "$command_file"
		command_file=$(command_path dropbearkey)
		[[ -n "$command_file" ]] || die 'dropbear is installed but dropbearkey is missing'
		stage_binary "$command_file"
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

SECTOR_SIZE=$(sfdisk --dump "$RAW" | awk '/^sector-size:/ { print $2; exit }')
DISK_SECTORS=$(blockdev --getsz "$DISK")
RAW_TABLE=$(sfdisk --dump "$RAW")
RAW_DISK_GUID=$(printf '%s\n' "$RAW_TABLE" | awk '/^label-id:/ { print $2; exit }')
RAW_P1_LINE=$(printf '%s\n' "$RAW_TABLE" | awk -v part="${RAW}1" '$1 == part { print; exit }')
RAW_P2_LINE=$(printf '%s\n' "$RAW_TABLE" | awk -v part="${RAW}2" '$1 == part { print; exit }')
RAW_P3_LINE=$(printf '%s\n' "$RAW_TABLE" | awk -v part="${RAW}3" '$1 == part { print; exit }')
