	printf 'target hostname: %s\n' "$TARGET_HOSTNAME"
	printf 'target network:  %s (%s) names=%s %s via %s DNS %s\n' "$TARGET_INTERFACE" "$TARGET_MAC" "$TARGET_INTERFACE_NAMES" "$TARGET_IPV4_CIDR" "$TARGET_GATEWAY" "${TARGET_DNS:-none}"
