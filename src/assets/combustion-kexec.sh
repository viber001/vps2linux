(#@INCLUDE@) src/assets/combustion-base.sh
(#@INCLUDE@) src/assets/combustion-user.sh

# Grow the root filesystem to fill its partition. The deployer normally does
# this before the first boot; this is a fallback for a source host without
# btrfs-progs. It is idempotent (a no-op once the filesystem fills the
# partition).
if command -v btrfs >/dev/null 2>&1; then
	btrfs filesystem resize max "\$ROOT" 2>/dev/null || true
fi
