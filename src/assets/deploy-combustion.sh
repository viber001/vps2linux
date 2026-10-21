CONFIG_OFFSET=$((CONFIG_START * SECTOR_SIZE))
CONFIG_BYTES=$((CONFIG_SIZE * SECTOR_SIZE))
CONFIG_LOOP=$(losetup --find --show --offset "$CONFIG_OFFSET" --sizelimit "$CONFIG_BYTES" "$DISK") || \
	fail 'cannot create a loop device for the Combustion partition'
cleanup_config() {
	umount /config 2>/dev/null || true
	losetup -d "$CONFIG_LOOP" 2>/dev/null || true
}
trap cleanup_config EXIT
# The RAM bootstrap stages mkfs.ext4 while the Debian initramfs only ships
# mke2fs (e2fsprogs-udeb); both create the same filesystem.
if command -v mkfs.ext4 >/dev/null 2>&1; then
	mkfs.ext4 -F -L combustion "$CONFIG_LOOP"
else
	mke2fs -F -t ext4 -L combustion "$CONFIG_LOOP"
fi
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
