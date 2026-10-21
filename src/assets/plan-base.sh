	printf 'source root:     %s (%s)\n' "$ROOT_SOURCE" "$(findmnt -nro FSTYPE /)"
	printf 'source disk:     %s\n' "$SOURCE_DISK"
	printf 'target disk:     %s (%s bytes, %s)\n' "$TARGET_DISK" "$disk_bytes" "${model:-unknown model}"
