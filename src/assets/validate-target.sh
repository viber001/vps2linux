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
	[[ "$REBOOT_DELAY" =~ ^[0-9]+$ ]] || die "invalid reboot delay: $REBOOT_DELAY seconds"
	[[ -s "$SSH_KEY_FILE" ]] || die "SSH authorized_keys file is missing or empty: $SSH_KEY_FILE"
	for marker in SSHKEYS USERKEYS \
		__VPS2IMG_ROOT_AUTHORIZED_KEYS__ __VPS2IMG_USER_AUTHORIZED_KEYS__; do
		if grep -Fqx -- "$marker" "$SSH_KEY_FILE"; then
			die "authorized_keys file contains the reserved line '$marker': remove or change that line before running"
		fi
	done
