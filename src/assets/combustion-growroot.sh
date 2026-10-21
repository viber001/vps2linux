# Grow the root filesystem to fill its partition. kexec does this in its
# initramfs before the first boot; pivot cannot (the old kernel still holds the
# former root's frozen btrfs superblock), so for pivot this is the only resize.
# It is idempotent (a no-op once the filesystem fills the partition).
if command -v btrfs >/dev/null 2>&1; then
	btrfs filesystem resize max "\$ROOT" 2>/dev/null || true
fi
