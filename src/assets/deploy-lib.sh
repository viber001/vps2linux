table_field() {
	local line=$1 key=$2 value
	# sfdisk pads values after the '=' (for example "start=     2048,"), so the
	# value is not necessarily part of the same whitespace-separated field.
	value=$(printf '%s\n' "$line" | awk -v key="$key" '{
		if (match($0, key "= *[^, ]+")) {
			value = substr($0, RSTART, RLENGTH)
			sub("^" key "= *", "", value)
			gsub(/,/, "", value)
			print value
			exit
		}
	}')
	printf '%s\n' "$value"
}

partition_path() {
	case "$1" in
		/dev/nvme*|/dev/mmcblk*|/dev/loop*) printf '%sp%s\n' "$1" "$2" ;;
		*) printf '%s%s\n' "$1" "$2" ;;
	esac
}
