# lsblk grew the PATH column in util-linux 2.27; older releases (for example
# CentOS 7's 2.23) reject it and abort under pipefail. KNAME exists on both,
# and is printed without the /dev/ prefix on old and new versions alike.
lsblk_whole_disk() {
	local node=$1
	lsblk -sno KNAME,TYPE "$node" 2>/dev/null |
		awk '$2 == "disk" { print ($1 ~ /^\// ? $1 : "/dev/" $1); exit }'
}

discover_source() {
	ROOT_SOURCE=$(findmnt -nro SOURCE /) || die 'cannot determine the current root source'
	# On a btrfs subvolume root findmnt prints the device with the subvolume,
	# for example /dev/sda3[/@/.snapshots/3/snapshot]; lsblk needs the device.
	ROOT_SOURCE=${ROOT_SOURCE%%\[*}
	# Only block devices can be walked up to a whole disk; a ZFS dataset or any
	# other non-device source name makes lsblk fail and would abort under
	# pipefail before the fallbacks below get a chance to run.
	if [[ -b "$ROOT_SOURCE" ]]; then
		SOURCE_DISK=$(lsblk_whole_disk "$ROOT_SOURCE")
	fi
	# An immutable OS image (for example Harvester/cOS) boots with the root on a
	# loop device whose backing file lives on another partition; lsblk -s on the
	# loop device reaches no disk, so resolve the backing file to the mount that
	# holds it and use that filesystem's disk instead.
	if [[ -z "$SOURCE_DISK" && -b "$ROOT_SOURCE" && "$(lsblk -dnro TYPE "$ROOT_SOURCE")" == loop ]]; then
		SOURCE_DISK=$(loop_backing_disk "$ROOT_SOURCE")
	fi
	# A ZFS dataset root (for example Proxmox VE's rpool/ROOT/pve-1) is not
	# a block device at all, so resolve the pool's leaf vdev and its whole disk.
	if [[ -z "$SOURCE_DISK" && "$ROOT_SOURCE" != /dev/* ]]; then
		SOURCE_DISK=$(dataset_backing_disk "$ROOT_SOURCE")
	fi
	[[ -n "$SOURCE_DISK" ]] || die "cannot determine the disk containing $ROOT_SOURCE"
	[[ -n "$TARGET_DISK" ]] || TARGET_DISK=$SOURCE_DISK
	[[ "$(lsblk -dnro TYPE "$TARGET_DISK")" == disk ]] || die "$TARGET_DISK is not a whole disk"
}

# Map the backing file of a loop-device root (for example /cOS/active.img on
# Harvester/cOS) to the whole disk that hosts it, by finding the mount whose
# target plus the backing path names an existing file.
loop_backing_disk() {
	local loop backing target source disk
	loop=$1
	backing=$(cat "/sys/block/${loop##*/}/loop/backing_file" 2>/dev/null) || return 0
	[[ -n "$backing" ]] || return 0
	while read -r target source; do
		[[ -e "$target$backing" ]] || continue
		disk=$(lsblk_whole_disk "$source")
		[[ -n "$disk" ]] && { printf '%s\n' "$disk"; return 0; }
	done < <(findmnt -rno TARGET,SOURCE)
	# Return success even when nothing matched: the caller reports the missing
	# disk itself, and a non-zero return here would abort under set -e.
	return 0
}

# Map a ZFS dataset root (for example Proxmox VE's rpool/ROOT/pve-1) to the
# whole disk holding the pool. The pool name is the first dataset component;
# zpool status -P lists leaf vdevs by full path, so the first /dev entry is
# enough to walk back to a whole disk with lsblk.
dataset_backing_disk() {
	local dataset pool dev disk
	dataset=$1
	pool=$(zfs list -H -o name "$dataset" 2>/dev/null) || return 0
	pool=${pool%%/*}
	[[ -n "$pool" ]] || return 0
	dev=$(zpool status -P "$pool" 2>/dev/null | awk '$1 ~ /^\/dev\// { print $1; exit }')
	[[ -n "$dev" ]] || return 0
	disk=$(lsblk_whole_disk "$dev")
	printf '%s\n' "${disk:-$dev}"
	return 0
}
