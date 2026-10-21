	printf 'root/config:     %s GiB Btrfs / Combustion to end of disk (min %s MiB)\n' "$ROOT_SIZE_GIB" "$CONFIG_SIZE_MIB"
	printf 'reboot delay:    %s seconds after the write\n' "${REBOOT_DELAY:-0}"
	printf 'SSH keys:        %s\n' "$SSH_KEY_FILE"
