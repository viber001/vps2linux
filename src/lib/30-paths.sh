command_path() {
	command -v "$1" 2>/dev/null || return 1
}

need_command() {
	command_path "$1" >/dev/null || die "required command is missing: $1"
}


# stage_binary copies an executable and every shared library it needs into a
# filesystem tree rooted at $1, preserving absolute paths so the interpreter and
# rpath references keep working inside the target environment.
stage_binary() {
	local root=$1 source=$2 real dependency dependency_real
	real=$(readlink -f "$source")
	[[ -x "$real" ]] || die "cannot stage executable: $source"
	mkdir -p "$root$(dirname "$source")" "$root$(dirname "$real")"
	# Resolve Debian alternatives/symlink entry points inside the new root;
	# copying the absolute symlink alone would point back at the old root.
	cp -aL "$source" "$root$source"
	cp -a "$real" "$root$real"
	while read -r dependency; do
		[[ -z "$dependency" || "$dependency" == linux-vdso* ]] && continue
		[[ -e "$dependency" || -L "$dependency" ]] || continue
		mkdir -p "$root$(dirname "$dependency")"
		cp -aL "$dependency" "$root$dependency"
		dependency_real=$(readlink -f "$dependency")
		if [[ -e "$dependency_real" ]]; then
			mkdir -p "$root$(dirname "$dependency_real")"
			cp -a "$dependency_real" "$root$dependency_real"
		fi
	done < <(ldd "$real" 2>/dev/null | awk '/=> \/[^ ]+/ { print $3 } /^[[:space:]]*\/[^ ]+/ { print $1 }')
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
