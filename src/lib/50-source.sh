discover_source() {
	ROOT_SOURCE=$(findmnt -nro SOURCE /) || die 'cannot determine the current root source'
	# On a btrfs subvolume root findmnt prints the device with the subvolume,
	# for example /dev/sda3[/@/.snapshots/3/snapshot]; lsblk needs the device.
	ROOT_SOURCE=${ROOT_SOURCE%%\[*}
	SOURCE_DISK=$(lsblk -sno PATH,TYPE "$ROOT_SOURCE" | awk '$2 == "disk" { print $1; exit }')
	# An immutable OS image (for example Harvester/cOS) boots with the root on a
	# loop device whose backing file lives on another partition; lsblk -s on the
	# loop device reaches no disk, so resolve the backing file to the mount that
	# holds it and use that filesystem's disk instead.
	if [[ -z "$SOURCE_DISK" && -b "$ROOT_SOURCE" && "$(lsblk -dnro TYPE "$ROOT_SOURCE")" == loop ]]; then
		SOURCE_DISK=$(loop_backing_disk "$ROOT_SOURCE")
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
		disk=$(lsblk -sno PATH,TYPE "$source" | awk '$2 == "disk" { print $1; exit }')
		[[ -n "$disk" ]] && { printf '%s\n' "$disk"; return 0; }
	done < <(findmnt -rno TARGET,SOURCE)
	# Return success even when nothing matched: the caller reports the missing
	# disk itself, and a non-zero return here would abort under set -e.
	return 0
}
