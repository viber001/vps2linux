# Grow the image's root filesystem to fill the (larger) root partition before
# the first boot. Filling the disk with the Combustion partition suppresses the
# image's own growroot / kiwi-repart first-boot resize, so grow it here or the
# Combustion script has to do it on the target.
#
# Only the kexec deployer can do this before booting: its fresh kernel has no
# stale btrfs state. The pivot deployer keeps running the old kernel, which
# still has the former root's btrfs superblock registered; after dd, mounting
# the same block device rejoins that stale superblock instead of the freshly
# written image, and btrfs filesystem resize blocks forever in sb_start_write
# because the former root is still frozen. So pivot sets GROW_ROOT_IN_RAM=no
# and leaves the resize to the Combustion script.
if [[ "${GROW_ROOT_IN_RAM:-yes}" != yes ]]; then
	printf '%s\n' 'Root filesystem will be grown by the target on first boot.'
else
	ROOT_PART=$(partition_path "$DISK" 3)
	if [[ -b "$ROOT_PART" ]] && command -v btrfs >/dev/null 2>&1; then
		command -v modprobe >/dev/null 2>&1 && modprobe btrfs 2>/dev/null || true
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
fi
