discover_source() {
	ROOT_SOURCE=$(findmnt -nro SOURCE /) || die 'cannot determine the current root source'
	# On a btrfs subvolume root findmnt prints the device with the subvolume,
	# for example /dev/sda3[/@/.snapshots/3/snapshot]; lsblk needs the device.
	ROOT_SOURCE=${ROOT_SOURCE%%\[*}
	SOURCE_DISK=$(lsblk -sno PATH,TYPE "$ROOT_SOURCE" | awk '$2 == "disk" { print $1; exit }')
	[[ -n "$SOURCE_DISK" ]] || die "cannot determine the disk containing $ROOT_SOURCE"
	[[ -n "$TARGET_DISK" ]] || TARGET_DISK=$SOURCE_DISK
	[[ "$(lsblk -dnro TYPE "$TARGET_DISK")" == disk ]] || die "$TARGET_DISK is not a whole disk"
}
