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
#
# This runs under the source kernel, which may be much older than the e2fsprogs
# that builds the filesystem: Debian's 1.47 enables metadata_csum_seed (needs
# Linux 4.13) and orphan_file (needs 5.15) by default, and an older kernel then
# refuses to mount /config. Strip those features when the running kernel cannot
# read them, and retry without the flags for an old e2fsprogs that does not know
# the feature names.
KREL=$(uname -r)
KMAJ=${KREL%%.*}
KMIN=${KREL#*.}
KMIN=${KMIN%%.*}
EXT4_COMPAT_OPTS=
if (( KMAJ < 4 || (KMAJ == 4 && KMIN < 13) )); then
	EXT4_COMPAT_OPTS='^metadata_csum_seed'
fi
if (( KMAJ < 5 || (KMAJ == 5 && KMIN < 15) )); then
	EXT4_COMPAT_OPTS="${EXT4_COMPAT_OPTS:+$EXT4_COMPAT_OPTS,}^orphan_file"
fi
MKFS_ARGS=(-F)
[[ -z "$EXT4_COMPAT_OPTS" ]] || MKFS_ARGS+=(-O "$EXT4_COMPAT_OPTS")
if command -v mkfs.ext4 >/dev/null 2>&1; then
	mkfs.ext4 "${MKFS_ARGS[@]}" -L combustion "$CONFIG_LOOP" || \
		mkfs.ext4 -F -L combustion "$CONFIG_LOOP"
else
	mke2fs "${MKFS_ARGS[@]}" -t ext4 -L combustion "$CONFIG_LOOP" || \
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
