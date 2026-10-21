	local nameserver bridge_member altname source_interface
	[[ -n "$TARGET_HOSTNAME" ]] || TARGET_HOSTNAME=$(hostname -s)
	[[ -n "$TARGET_INTERFACE" ]] || TARGET_INTERFACE=$(ip -4 route show default | awk 'NR == 1 { print $5; exit }')
	[[ -n "$TARGET_INTERFACE" ]] || die 'cannot determine the default network interface; set --interface'
	# The source address and default route live on the interface that carries
	# them (a bridge such as vmbrX), not on its physical member. Remember it
	# before the member mapping below and use it to discover IPv4/gateway.
	source_interface=$TARGET_INTERFACE
	# A PVE host's vmbrX is not a deployable interface. Resolve its physical
	# bridge member first, then preserve the member name and all kernel altnames.
	if [[ "$TARGET_INTERFACE" == vmbr* ]]; then
		bridge_member=$(ip -o link show master "$TARGET_INTERFACE" | awk -F': |@' 'NR == 1 { print $2; exit }')
		if [[ -n "$bridge_member" ]]; then
			warn "mapping source bridge $TARGET_INTERFACE to target interface $bridge_member"
			TARGET_INTERFACE=$bridge_member
		else
			warn "source bridge $TARGET_INTERFACE has no visible member; target will use fallback discovery"
		fi
	fi
	[[ -n "$TARGET_INTERFACE_NAMES" ]] || TARGET_INTERFACE_NAMES=$TARGET_INTERFACE
	while read -r altname; do
		[[ -n "$altname" ]] || continue
		case ",$TARGET_INTERFACE_NAMES," in
			*,"$altname",*) ;;
			*) TARGET_INTERFACE_NAMES="$TARGET_INTERFACE_NAMES,$altname" ;;
		esac
	done < <(ip -o link show dev "$TARGET_INTERFACE" | awk '{ for (i = 1; i <= NF; i++) if ($i == "altname") { name = $(i + 1); sub(/\\$/, "", name); print name } }')
	if [[ -z "$TARGET_MAC" ]]; then
		[[ -r "/sys/class/net/$TARGET_INTERFACE/address" ]] || die "cannot determine MAC address for $TARGET_INTERFACE"
		TARGET_MAC=$(cat "/sys/class/net/$TARGET_INTERFACE/address")
	fi
	TARGET_MAC=$(printf '%s' "$TARGET_MAC" | tr '[:upper:]' '[:lower:]')
	[[ -n "$TARGET_IPV4_CIDR" ]] || \
		TARGET_IPV4_CIDR=$(ip -4 -o addr show dev "$TARGET_INTERFACE" scope global | awk 'NR == 1 { print $4; exit }')
	[[ -n "$TARGET_IPV4_CIDR" ]] || \
		TARGET_IPV4_CIDR=$(ip -4 -o addr show dev "$source_interface" scope global | awk 'NR == 1 { print $4; exit }')
	[[ -n "$TARGET_IPV4_CIDR" ]] || die 'cannot determine the current IPv4 address; set --ipv4'
	[[ -n "$TARGET_GATEWAY" ]] || \
		TARGET_GATEWAY=$(ip -4 route show default dev "$TARGET_INTERFACE" | awk 'NR == 1 { print $3; exit }')
	[[ -n "$TARGET_GATEWAY" ]] || \
		TARGET_GATEWAY=$(ip -4 route show default dev "$source_interface" | awk 'NR == 1 { print $3; exit }')
	[[ -n "$TARGET_GATEWAY" ]] || \
		TARGET_GATEWAY=$(ip -4 route show default | awk 'NR == 1 { print $3; exit }')
	[[ -n "$TARGET_GATEWAY" ]] || die 'cannot determine the default gateway; set --gateway'
	if [[ -z "$TARGET_DNS" ]]; then
		nameserver=$(awk '/^nameserver[[:space:]]+/ { print $2 }' /etc/resolv.conf | paste -sd ';' -)
		TARGET_DNS=$nameserver
	fi
	TARGET_DNS=${TARGET_DNS//,/;}
	TARGET_DNS=${TARGET_DNS// /;}
	[[ "$TARGET_DNS" == '' || "$TARGET_DNS" == *';' ]] || TARGET_DNS+=';'
