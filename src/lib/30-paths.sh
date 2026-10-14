command_path() {
	command -v "$1" 2>/dev/null || return 1
}

need_command() {
	command_path "$1" >/dev/null || die "required command is missing: $1"
}

partition_path() {
	case "$1" in
		/dev/nvme*|/dev/mmcblk*|/dev/loop*) printf '%sp%s\n' "$1" "$2" ;;
		*) printf '%s%s\n' "$1" "$2" ;;
	esac
}

download_file() {
	local url=$1 destination=$2
	if command -v curl >/dev/null 2>&1; then
		curl --fail --location --retry 3 --output "$destination" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget --tries=3 --output-document="$destination" "$url"
	else
		die 'curl or wget is required to download the image'
	fi
}
