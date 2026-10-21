(#@INCLUDE@expand) src/assets/deploy-lib.sh
GPT_SOURCE=$DISK
(#@INCLUDE@expand) src/assets/deploy-gpt.sh
(#@INCLUDE@expand) src/assets/deploy-combustion.sh

(#@HEREDOC@expand) cat > /config/combustion/script <<COMBUSTION | src/assets/combustion.sh
chmod 0700 /config/combustion/script
sync
umount /config
losetup -d "$CONFIG_LOOP"
trap - EXIT

# Refresh the kernel partition table to the freshly written GPT before the
# root filesystem is mounted to grow it.
blockdev --rereadpt "$DISK" 2>/dev/null || true

(#@INCLUDE@expand) src/assets/deploy-growroot.sh
(#@INCLUDE@expand) src/assets/deploy-efi.sh
flush_disk
(#@INCLUDE@expand) src/assets/deploy-reboot.sh
DEPLOY
	chmod 0755 "$STAGE/deploy"
}

build_initramfs() {
	case "$RAMDISK_SOURCE" in
		host) build_initramfs_host ;;
		debian) build_initramfs_debian ;;
		*) die "invalid --ramdisk-source: $RAMDISK_SOURCE (use host or debian)" ;;
	esac
}

ramdisk_source_description() {
	if [[ "$RAMDISK_SOURCE" == debian ]]; then
		printf 'Debian installer (d-i) components (%s %s/%s, assembled without the host package manager)' \
			"$DI_MIRROR" "$DI_SUITE" "$DI_ARCH"
	else
		printf 'host system tools (busybox + staged host binaries and libraries)'
	fi
}

di_url() {
	printf '%s/dists/%s/%s\n' "$DI_MIRROR" "$DI_SUITE" "$1"
}

# fetch_debian_index downloads and caches a Debian Packages index: the ordinary
# .deb archive or the debian-installer .udeb archive for the target suite/arch.
fetch_debian_index() {
	local dist=$1 rel destination url
	case "$dist" in
		deb) rel="main/binary-$DI_ARCH/Packages.gz"; destination=$DI_DEB_INDEX ;;
		udeb) rel="main/debian-installer/binary-$DI_ARCH/Packages.gz"; destination=$DI_UDEB_INDEX ;;
		*) die "internal error: unknown Debian index '$dist'" ;;
	esac
	[[ -s "$destination" ]] && return 0
	url=$(di_url "$rel")
	printf 'Fetching Debian %s index: %s\n' "$dist" "$url"
	download_file "$url" "$destination.download"
	gzip -dc "$destination.download" > "$destination"
	rm -f "$destination.download"
	[[ -s "$destination" ]] || die "the Debian $dist index is empty: $url"
}

# di_parse_index turns a Packages index into the lookup tables used by the
# resolver: package name -> Filename and package name -> Depends/Pre-Depends.
# Debian field continuation lines (which start with a space) are ignored, which
# is safe because in practice only Description/Tag wrap.
di_parse_index() {
	local dist=$1 file=$2 name filename dependencies sha256 key empty_field
	empty_field=__VPS2IMG_EMPTY_FIELD__
	[[ -n "${DI_INDEX_PARSED[$dist]:-}" ]] && return 0
	DI_INDEX_PARSED[$dist]=1
	while IFS=$'\t' read -r name filename dependencies sha256; do
		[[ -n "$name" && -n "$filename" ]] || continue
		[[ "$dependencies" == "$empty_field" ]] && dependencies=
		[[ "$sha256" == "$empty_field" ]] && sha256=
		key=$dist/$name
		DI_PKG_FILE[$key]=$filename
		DI_PKG_DEP[$key]=$dependencies
		DI_PKG_SHA256[$key]=$sha256
		DI_PKG_DISTS[$name]="${DI_PKG_DISTS[$name]:-}${DI_PKG_DISTS[$name]:+ }$dist"
	done < <(awk -v dist="$dist" -v empty="$empty_field" '
		function serialized(value) {
			return value == "" ? empty : value
		}
		function field_value(line) {
			sub(/^[^:]*:[[:space:]]*/, "", line)
			return line
		}
		/^Package:/ { name=field_value($0) }
		/^Filename:/ { filename=field_value($0) }
		/^SHA256:/ {
			sha256=field_value($0)
		}
		/^Depends:/ {
			value=field_value($0)
			dependencies=dependencies (dependencies?" ":"") value
		}
		/^Pre-Depends:/ {
			value=field_value($0)
			dependencies=dependencies (dependencies?" ":"") value
		}
		/^$/{ if(name!=""){ print name "\t" filename "\t" serialized(dependencies) "\t" serialized(sha256) } name="";filename="";dependencies="";sha256="" }
		END{ if(name!=""){ print name "\t" filename "\t" serialized(dependencies) "\t" serialized(sha256) } }
	' "$file")
}

load_debian_indexes() {
	fetch_debian_index deb
	fetch_debian_index udeb
	di_parse_index deb "$DI_DEB_INDEX"
	di_parse_index udeb "$DI_UDEB_INDEX"
}

# resolve_debian_packages walks the dependency graph of the requested packages,
# following shared-library dependencies (names starting with "lib") recursively
# so the assembled initramfs has a complete runtime closure.  The result is the
# global RESOLVED_DEBS array of tab-separated "dist filename sha256" entries.
resolve_debian_packages() {
	local -a queue=("$@")
	local name key dist dependency depspec old_ifs
	local -A resolved=()
	RESOLVED_DEBS=()
	while ((${#queue[@]})); do
		name=${queue[0]}
		queue=("${queue[@]:1}")
		[[ -n "$name" ]] || continue
		[[ -n "${resolved[$name]:-}" ]] && continue
		resolved[$name]=1
		if [[ -z "${DI_PKG_DISTS[$name]:-}" ]]; then
			warn "Debian package not found in $DI_SUITE/$DI_ARCH: $name"
			continue
		fi
		for dist in ${DI_PKG_DISTS[$name]}; do
			key=$dist/$name
			RESOLVED_DEBS+=("$dist"$'\t'"${DI_PKG_FILE[$key]}"$'\t'"${DI_PKG_SHA256[$key]:-}")
			depspec=${DI_PKG_DEP[$key]:-}
			old_ifs=$IFS
			IFS=,
			for dependency in $depspec; do
				dependency=${dependency%%|*}
				dependency=${dependency#"${dependency%%[![:space:]]*}"}
				dependency=${dependency%% *}
				dependency=${dependency%%:*}
				[[ -n "$dependency" ]] || continue
				[[ "$dependency" == lib* ]] || continue
				queue+=("$dependency")
			done
			IFS=$old_ifs
		done
	done
}

# extract_package_into unpacks the data.tar member of a .deb/.udeb into the tree
# rooted at $2.  Only the archive tooling (ar + tar with the right decompressor)
# is needed, never the host package manager.
extract_package_into() {
	local archive=$1 destination=$2 member
	member=$(ar_command t "$archive" | awk '/^data\.tar/{ print; exit }')
	[[ -n "$member" ]] || die "no data.tar member in $archive"
	case "$member" in
		*.tar.xz) ar_command p "$archive" "$member" | tar --no-same-owner -xJ -C "$destination" ;;
		*.tar.zst) ar_command p "$archive" "$member" | tar --no-same-owner --zstd -x -C "$destination" ;;
		*.tar.gz) ar_command p "$archive" "$member" | tar --no-same-owner -xz -C "$destination" ;;
		*.tar.bz2) ar_command p "$archive" "$member" | tar --no-same-owner -xj -C "$destination" ;;
		*.tar) ar_command p "$archive" "$member" | tar --no-same-owner -x -C "$destination" ;;
		*) die "unknown data.tar compression in $archive ($member)" ;;
	esac
}

verify_debian_package() {
	local archive=$1 expected=$2 label=$3
	[[ "$VERIFY_DEBIAN_PACKAGES" == 1 ]] || return 0
	[[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] || \
		die "Debian package has no valid SHA-256 in the Packages index: $label"
	expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
	if ! printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null; then
		die "Debian package SHA-256 verification failed: $label"
	fi
}

stage_debian_packages() {
	local entry dist filename expected_hash destination url
	for entry in "${RESOLVED_DEBS[@]}"; do
		IFS=$'\t' read -r dist filename expected_hash <<< "$entry"
		destination="$WORKDIR/debs/$(basename "$filename")"
		if [[ ! -s "$destination" ]]; then
			url="$DI_MIRROR/$filename"
			printf 'Downloading Debian %s package: %s\n' "$dist" "$url"
			download_file "$url" "$destination"
		fi
		verify_debian_package "$destination" "$expected_hash" "$filename"
		extract_package_into "$destination" "$STAGE"
	done
}

unpack_debian_initrd() {
	local archive=$WORKDIR/debian-initrd.gz url
	if [[ ! -s "$archive" ]]; then
		url=$(di_url "main/installer-$DI_ARCH/current/images/netboot/debian-installer/$DI_ARCH/initrd.gz")
		printf 'Fetching Debian installer initrd: %s\n' "$url"
		download_file "$url" "$archive"
	fi
	rm -rf "$STAGE"
	mkdir -p "$STAGE"
	( cd "$STAGE" && gzip -dc "$archive" | cpio -i -d -m --no-absolute-filenames ) || \
		die 'cannot unpack the Debian installer initrd'
}

# ensure_host_kexec makes a kexec binary available for the host-side kexec step.
# It prefers the host's own kexec and otherwise extracts kexec-tools (with its
# dependency closure, including kexec-tools' libxen* libraries) into $WORKDIR so
# no host package manager is involved.  The extracted library directories are
# added to LD_LIBRARY_PATH for the kexec calls.
ensure_host_kexec() {
	local entry dist filename expected_hash destination kexec_path libdirs
	[[ -n "$KEXEC_BIN" ]] && return 0
	if KEXEC_BIN=$(command_path kexec); then
		return 0
	fi
	[[ "$RAMDISK_SOURCE" == debian ]] || die 'kexec is required on the host'
	printf '%s\n' 'kexec is not installed on the host; fetching Debian kexec-tools for the kexec step'
	mkdir -p "$WORKDIR/debs" "$WORKDIR/hostbin"
	load_debian_indexes
	resolve_debian_packages kexec-tools
	for entry in "${RESOLVED_DEBS[@]}"; do
		IFS=$'\t' read -r dist filename expected_hash <<< "$entry"
		destination="$WORKDIR/debs/$(basename "$filename")"
		if [[ ! -s "$destination" ]]; then
			printf 'Downloading Debian %s package: %s\n' "$dist" "$DI_MIRROR/$filename"
			download_file "$DI_MIRROR/$filename" "$destination"
		fi
		verify_debian_package "$destination" "$expected_hash" "$filename"
		extract_package_into "$destination" "$WORKDIR/hostbin"
	done
	kexec_path=$(find "$WORKDIR/hostbin" -type f -name kexec -perm -u+x 2>/dev/null | head -n1)
	[[ -n "$kexec_path" ]] || die 'the Debian kexec-tools package did not provide a kexec binary'
	libdirs=$(find "$WORKDIR/hostbin" -type d -name '*-linux-gnu' 2>/dev/null | paste -sd: -)
	LD_LIBRARY_PATH="${libdirs}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	export LD_LIBRARY_PATH
	KEXEC_BIN=$kexec_path
	printf 'Using kexec binary: %s\n' "$KEXEC_BIN"
}

build_initramfs_debian() {
	local dropbear_path
	printf 'Ramdisk source: %s\n' "$(ramdisk_source_description)"
	rm -rf "$STAGE"
	mkdir -p "$WORKDIR/debs"
	unpack_debian_initrd
	load_debian_indexes
	# Base tools that turn the Debian installer initrd into the deploy ramdisk.
	# util-linux gives lsblk/findmnt/partx/blockdev/blkid; the separate mount
	# package gives losetup (Debian 13 moved it out of util-linux); coreutils
	# gives timeout/setsid/sync/sha256sum; gdisk gives sgdisk; efibootmgr gives
	# efibootmgr; iproute2 gives ip; kmod gives modprobe/modinfo; dropbear-bin
	# gives dropbear (SSH rescue); bash is the /init interpreter; zlib1g is the
	# one non-"lib"-named runtime dependency (dropbear and btrfs link it).
	# The udebs give sfdisk (fdisk-udeb), mke2fs (e2fsprogs-udeb) and btrfs
	# (btrfs-progs-udeb).  Shared-library dependencies are resolved recursively.
	local -a debian_packages=(
		util-linux coreutils mount bash libtinfo6 zlib1g gdisk efibootmgr
		kexec-tools kmod iproute2 dropbear-bin
		fdisk-udeb e2fsprogs-udeb btrfs-progs-udeb
	)
	resolve_debian_packages "${debian_packages[@]}"
	stage_debian_packages
	# Documentation and translations dominate the size of a full .deb
	# extraction and no deploy tool reads them, so drop them to keep the
	# initramfs small enough for kexec_file_load.
	rm -rf "$STAGE/usr/share/doc" "$STAGE/usr/share/man" "$STAGE/usr/share/info" \
		"$STAGE/usr/share/locale" "$STAGE/usr/share/bash-completion" \
		"$STAGE/usr/share/doc-base" "$STAGE/usr/share/gettext" \
		"$STAGE/usr/share/lintian" "$STAGE/usr/share/bug"
	# The Debian installer ships busybox at /usr/bin/busybox; /init expects it at
	# /bin/busybox.  The d-i busybox has no mdev applet, which /init tolerates.
	mkdir -p "$STAGE/bin"
	ln -sf /usr/bin/busybox "$STAGE/bin/busybox"
	# dropbear self-generates a host key at start when none is supplied, so no
	# host-side dropbearkey is needed in Debian mode.
	dropbear_path=$(find "$STAGE/usr/sbin" "$STAGE/usr/bin" "$STAGE/sbin" "$STAGE/bin" \
		-maxdepth 1 -type f -name dropbear 2>/dev/null | head -n1)
	if [[ -n "$dropbear_path" ]]; then
		DROPBEAR_BIN=${dropbear_path#"$STAGE"}
	else
		DROPBEAR_BIN=
		warn 'dropbear was not found in the Debian packages; SSH rescue will be unavailable'
	fi
	DROPBEAR_KEY=
	rm -f "$STAGE/init" "$STAGE/deploy"
	finalize_initramfs
}

build_initramfs_host() {
	local command_name command_file
	rm -rf "$STAGE"
	mkdir -p "$STAGE"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,proc,sys,dev,tmp,run,config,etc/dropbear,root/.ssh}

	# Static busybox provides the shell applets (sh, wget, dd, head, sha256sum,
	# ip, blockdev, setsid, ...) and keeps the initramfs small.
	cp -L "$(command_path busybox)" "$STAGE/bin/busybox"
	[[ -x "$STAGE/bin/busybox" ]] || die 'busybox is not executable'

	for command_name in bash blkid dd dropbear efibootmgr findmnt losetup lsblk mke2fs partx sfdisk sgdisk; do
		command_file=$(command_path "$command_name")
		[[ -n "$command_file" ]] || die "cannot stage command into the initramfs: $command_name"
		stage_binary "$STAGE" "$command_file"
	done
	# btrfs-progs grows the image's root filesystem to fill its partition; it is
	# optional so the deploy still works on a source without btrfs-progs (the
	# Combustion script grows the filesystem as a fallback).
	if command_file=$(command_path btrfs); then
		stage_binary "$STAGE" "$command_file"
	else
		warn 'btrfs is not installed on the source; the root filesystem will be grown by the target instead'
	fi
	DROPBEAR_BIN=$(command_path dropbear)
	DROPBEAR_KEY=
	finalize_initramfs
}

# finalize_initramfs adds the parts common to both ramdisk sources: the in-use
# kernel modules and firmware, the account files, the deploy scripts and the
# environment, then packs everything into a gzip cpio initramfs.
finalize_initramfs() {
	mkdir -p "$STAGE"/{proc,sys,dev,tmp,run,config,etc/dropbear,root/.ssh}

	# The kernel modules still come from the host's /lib/modules/$(uname -r):
	# kexec loads the RUNNING kernel, so ONLY modules built for that exact
	# kernel are valid.  This is the one unavoidable host dependency of the
	# Debian ramdisk source; it is not something the d-i components can replace.
	stage_kernel_modules
	stage_firmware

	# Minimal account/database files so dropbear can resolve root and exec a shell.
	printf 'root:x:0:0:root:/root:/bin/sh\n' > "$STAGE/etc/passwd"
	printf 'root:x:0:\n' > "$STAGE/etc/group"
	printf '/bin/sh\n/bin/bash\n' > "$STAGE/etc/shells"
	printf 'passwd: files\ngroup: files\n' > "$STAGE/etc/nsswitch.conf"

	# In host mode a throwaway dropbear host key is generated on the source host.
	# In Debian mode dropbear generates its own key at start (no host dropbearkey).
	if [[ "$RAMDISK_SOURCE" == host ]]; then
		if dropbearkey -t ed25519 -f "$STAGE/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1; then
			DROPBEAR_KEY=/etc/dropbear/dropbear_ed25519_host_key
		elif dropbearkey -t rsa -s 2048 -f "$STAGE/etc/dropbear/dropbear_rsa_host_key" >/dev/null 2>&1; then
			DROPBEAR_KEY=/etc/dropbear/dropbear_rsa_host_key
		else
			die 'dropbearkey could not generate a host key'
		fi
		chmod 600 "$STAGE/etc/dropbear/"* 2>/dev/null || true
	fi

	cp -aL "$SSH_KEY_FILE" "$STAGE/authorized_keys"
	cp -aL "$SSH_KEY_FILE" "$STAGE/root/.ssh/authorized_keys"
	chmod 600 "$STAGE/root/.ssh/authorized_keys"

	# embed mode carries the raw image; stream mode does not (the whole point).
	if [[ "$IMAGE_MODE" == embed ]]; then
		if [[ "$(stat -c %d "$RAW_FILE")" == "$(stat -c %d "$STAGE")" ]]; then
			ln -f "$RAW_FILE" "$STAGE/image.raw"
		else
			cp -a "$RAW_FILE" "$STAGE/image.raw"
		fi
	fi

	{
		printf 'DISK=%q\n' "$TARGET_DISK"
		printf 'IMAGE_MODE=%q\n' "$IMAGE_MODE"
		printf 'IMAGE_RAW_URL=%q\n' "$IMAGE_RAW_URL"
		printf 'IMAGE_SHA256=%q\n' "$IMAGE_SHA256"
		printf 'IMAGE_SIZE=%q\n' "$IMAGE_SIZE"
		printf 'VERIFY_IMAGE=%q\n' "$VERIFY_IMAGE"
		printf 'SCRATCH_OFFSET=%q\n' "$SCRATCH_OFFSET"
		printf 'SCRATCH_BYTES=%q\n' "$SCRATCH_BYTES"
		printf 'DROPBEAR_BIN=%q\n' "$DROPBEAR_BIN"
		printf 'DROPBEAR_KEY=%q\n' "$DROPBEAR_KEY"
		printf 'TARGET_HOSTNAME=%q\n' "$TARGET_HOSTNAME"
		printf 'TARGET_INTERFACE=%q\n' "$TARGET_INTERFACE"
		printf 'TARGET_INTERFACE_NAMES=%q\n' "$TARGET_INTERFACE_NAMES"
		printf 'TARGET_MAC=%q\n' "$TARGET_MAC"
		printf 'TARGET_IPV4_CIDR=%q\n' "$TARGET_IPV4_CIDR"
		printf 'TARGET_GATEWAY=%q\n' "$TARGET_GATEWAY"
		printf 'TARGET_DNS=%q\n' "$TARGET_DNS"
		printf 'TARGET_USER=%q\n' "$TARGET_USER"
		printf 'TARGET_PASSWORD=%q\n' "$TARGET_PASSWORD"
		printf 'TARGET_NIC_DRIVERS=%q\n' "$TARGET_NIC_DRIVERS"
		printf 'TARGET_DISK_DRIVERS=%q\n' "$TARGET_DISK_DRIVERS"
		printf 'ROOT_SIZE_GIB=%q\n' "$ROOT_SIZE_GIB"
		printf 'CONFIG_SIZE_MIB=%q\n' "$CONFIG_SIZE_MIB"
		printf 'REBOOT_DELAY=%q\n' "$REBOOT_DELAY"
	} > "$STAGE/deploy.env"

	write_init
	write_deploy
	/usr/bin/bash -n "$STAGE/init"
	/usr/bin/bash -n "$STAGE/deploy"

	printf 'Building initramfs: %s\n' "$INITRAMFS"
	( cd "$STAGE" && find . -print0 | cpio -0 -o -H newc 2>/dev/null ) | gzip -6 > "$INITRAMFS"
	[[ -s "$INITRAMFS" ]] || die 'the initramfs archive is empty'
	rm -rf "$STAGE"
}

# load_kexec_image loads the running kernel plus the generated initramfs into the
# kexec slot. Under UEFI Secure Boot the kernel is locked down and only
# kexec_file_load (-s) is permitted, and only for a kernel image the firmware
# already trusts -- the running, signed kernel that booted under Secure Boot.
# kexec_load (-c) is kept as a fallback for a host without lockdown, where the
# legacy syscall is still allowed.
load_kexec_image() {
	local command_line=$1
	printf 'Loading kernel with kexec_file_load (-s): %s\n' "$KEXEC_KERNEL"
	if "$KEXEC_BIN" -s -l "$KEXEC_KERNEL" --initrd="$INITRAMFS" --command-line="$command_line"; then
		KEXEC_METHOD=file
		return 0
	fi
	if (( KEXEC_LOCKDOWN )); then
		die 'kexec_file_load (-s) was rejected while lockdown is active; the running kernel was not accepted as a trusted image'
	fi
	printf '%s\n' 'kexec_file_load (-s) failed; falling back to kexec_load (-c)'
	"$KEXEC_BIN" -c -l "$KEXEC_KERNEL" --initrd="$INITRAMFS" --command-line="$command_line" || \
		die 'kexec could not load the kernel with either kexec_file_load (-s) or kexec_load (-c)'
	KEXEC_METHOD=legacy
}

# unload_kexec_image clears whatever load_kexec_image put in the kexec slot,
# preferring the syscall that actually loaded it.
unload_kexec_image() {
	if [[ "$KEXEC_METHOD" == legacy ]]; then
		"$KEXEC_BIN" -c -u 2>/dev/null || "$KEXEC_BIN" -u
	else
		"$KEXEC_BIN" -s -u 2>/dev/null || "$KEXEC_BIN" -u
	fi
}

run_kexec() {
	local command_line
	command_line="console=ttyS0,115200 console=tty0 panic=120 vps2img-kexec.disk=$TARGET_DISK"
	load_kexec_image "$command_line"
	printf '%s\n' 'Switching kernels with kexec -e; the old kernel and systemd are discarded now.'
	sync
	"$KEXEC_BIN" -e
}

parse_args() {
	EXECUTE=0
	STAGE_TEST=0
	while (($#)); do
		case $1 in
			--image-url) IMAGE_URL=${2:?missing value for --image-url}; shift 2 ;;
			--image-file) IMAGE_FILE=${2:?missing value for --image-file}; shift 2 ;;
			--image-raw-url) IMAGE_URL=${2:?missing value for --image-raw-url}; shift 2 ;;
			--sha256) IMAGE_SHA256=${2:?missing value for --sha256}; shift 2 ;;
			--verify-image) VERIFY_IMAGE=1; shift ;;
			--no-verify-image) VERIFY_IMAGE=0; shift ;;
			--image-size) IMAGE_SIZE=${2:?missing value for --image-size}; shift 2 ;;
			--disk) TARGET_DISK=${2:?missing value for --disk}; shift 2 ;;
			--hostname) TARGET_HOSTNAME=${2:?missing value for --hostname}; shift 2 ;;
			--interface) TARGET_INTERFACE=${2:?missing value for --interface}; shift 2 ;;
			--ipv4) TARGET_IPV4_CIDR=${2:?missing value for --ipv4}; shift 2 ;;
			--gateway) TARGET_GATEWAY=${2:?missing value for --gateway}; shift 2 ;;
			--dns) TARGET_DNS=${2:?missing value for --dns}; shift 2 ;;
			--user) TARGET_USER=${2:?missing value for --user}; shift 2 ;;
			--password) TARGET_PASSWORD=${2:?missing value for --password}; shift 2 ;;
			--ssh-key-file) SSH_KEY_FILE=${2:?missing value for --ssh-key-file}; shift 2 ;;
			--root-size-gib) ROOT_SIZE_GIB=${2:?missing value for --root-size-gib}; shift 2 ;;
			--config-size-mib) CONFIG_SIZE_MIB=${2:?missing value for --config-size-mib}; shift 2 ;;
			--reboot-delay) REBOOT_DELAY=${2:?missing value for --reboot-delay}; shift 2 ;;
			--kernel) KEXEC_KERNEL=${2:?missing value for --kernel}; shift 2 ;;
			--ramdisk-source) RAMDISK_SOURCE=${2:?missing value for --ramdisk-source}; shift 2 ;;
			--verify-debian-packages) VERIFY_DEBIAN_PACKAGES=1; shift ;;
			--no-verify-debian-packages) VERIFY_DEBIAN_PACKAGES=0; shift ;;
			--di-mirror) DI_MIRROR=${2:?missing value for --di-mirror}; shift 2 ;;
			--di-suite) DI_SUITE=${2:?missing value for --di-suite}; shift 2 ;;
			--di-arch) DI_ARCH=${2:?missing value for --di-arch}; shift 2 ;;
			--image-mode) IMAGE_MODE_REQUEST=${2:?missing value for --image-mode}; shift 2 ;;
			--scratch-mib) SCRATCH_MIB=${2:?missing value for --scratch-mib}; shift 2 ;;
			--execute) EXECUTE=1; shift ;;
			--dry-run) EXECUTE=0; shift ;;
			--stage-test) EXECUTE=0; STAGE_TEST=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) die "unknown option: $1" ;;
		esac
	done
}

main() {
	parse_args "$@"
	[[ $EUID -eq 0 ]] || die 'run as root'
	[[ "$VERIFY_DEBIAN_PACKAGES" == 0 || "$VERIFY_DEBIAN_PACKAGES" == 1 ]] || \
		die "invalid Debian package verification setting: $VERIFY_DEBIAN_PACKAGES (use 0 or 1)"
	resolve_ramdisk_source
	resolve_image_mode
	check_dependencies
	check_kexec_support
	discover_source
	discover_configuration
	detect_kernel
	prepare_image
	print_plan

	if (( STAGE_TEST )); then
		ensure_host_kexec
		build_initramfs
		printf 'STAGE-TEST: initramfs is %s bytes\n' "$(stat -c '%s' "$INITRAMFS")"
		load_kexec_image "console=ttyS0,115200 console=tty0 panic=120 vps2img-kexec.disk=$TARGET_DISK"
		unload_kexec_image
		printf '%s\n' "STAGE-TEST: initramfs scripts syntax-checked and kexec load/unload succeeded (method=$KEXEC_METHOD); no kernel switch and no disk change."
		[[ "${VPS2IMG_KEXEC_KEEP_INITRAMFS:-0}" == 1 ]] || rm -f "$INITRAMFS"
		return 0
	fi

	if (( ! EXECUTE )); then
		printf '%s\n' 'DRY-RUN: no disk, mount, kexec, or reboot operation was performed.'
		return 0
	fi
	[[ "${VPS2IMG_KEXEC_CONFIRM:-}" == "WIPE:$TARGET_DISK" ]] || \
		die "set VPS2IMG_KEXEC_CONFIRM=WIPE:$TARGET_DISK to allow the destructive operation"
	[[ "$SOURCE_DISK" == "$TARGET_DISK" ]] || warn 'target is not the current root disk; verify it before continuing'
	if [[ "$IMAGE_MODE" == disk ]]; then
		stage_image_on_disk
	fi
	ensure_host_kexec
	build_initramfs
	run_kexec
}

main "$@"
