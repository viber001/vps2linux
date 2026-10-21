(#@INCLUDE@expand) src/assets/deploy-lib.sh
GPT_SOURCE=$RAW
(#@INCLUDE@expand) src/assets/deploy-gpt.sh
(#@INCLUDE@expand) src/assets/deploy-combustion.sh

(#@HEREDOC@expand) cat > /config/combustion/script <<COMBUSTION | src/assets/combustion.sh
chmod 0700 /config/combustion/script
sync
umount /config
losetup -d "$CONFIG_LOOP"
trap - EXIT

# The old kernel still has the former root's btrfs superblock registered, so a
# post-dd mount would rejoin that stale superblock instead of the new image.
# Leave the resize to the Combustion script on the target.
GROW_ROOT_IN_RAM=no
(#@INCLUDE@expand) src/assets/deploy-growroot.sh
(#@INCLUDE@expand) src/assets/deploy-efi.sh
flush_disk
(#@INCLUDE@expand) src/assets/deploy-reboot.sh
INNER
	chmod 0755 "$BOOTSTRAP/run/deploy"
}

run_from_bootstrap() {
	local oldroot="$BOOTSTRAP/oldroot" mountpoint node type
	local node type mountpoint
	# EFI (/boot/efi) and any separate /boot partition must be detached before
	# the target disk is overwritten.  The inner check remains as a second
	# guard after pivot_root.
	while read -r node type; do
		[[ "$type" == part ]] || continue
		while read -r mountpoint; do
			[[ -n "$mountpoint" ]] || continue
			# The active root must move through pivot_root first.  It cannot be
			# unmounted while this shell is still running from that root.
			[[ "$mountpoint" == / ]] && continue
			umount -Rl "$mountpoint" 2>/dev/null || umount -l "$mountpoint" 2>/dev/null || \
				die "cannot detach target mount: $node at $mountpoint"
		done < <(findmnt -rn -S "$node" -o TARGET)
	done < <(lsblk -nrpo NAME,TYPE "$TARGET_DISK")
	mount --rbind /dev "$BOOTSTRAP/dev"
	mount --make-rslave "$BOOTSTRAP/dev"
	mount --rbind /proc "$BOOTSTRAP/proc"
	mount --make-rslave "$BOOTSTRAP/proc"
	mount --rbind /sys "$BOOTSTRAP/sys"
	mount --make-rslave "$BOOTSTRAP/sys"
	mkdir -p "$oldroot"
	mount --make-rprivate /
	mount --make-rprivate "$BOOTSTRAP"
	pivot_root "$BOOTSTRAP" "$oldroot"
	cd /
	for mountpoint in /oldroot/dev /oldroot/proc /oldroot/sys; do
		umount -Rl "$mountpoint" 2>/dev/null || true
	done
	# Keep /oldroot mounted until the inner deployer has flushed it and
	# switched it read-only by blockdev --setro. It then detaches it before
	# writing the new image.
	export VPS2IMG_PIVOT_ROOT_SOURCE="$ROOT_SOURCE"
	# When a rescue dropbear is staged, the inner deployer terminates the old
	# sshd to free port 22, and this bootstrap shell shares that sshd's
	# controlling terminal: detach first (ignore SIGHUP, move stdio to the
	# console) so the deployer survives and owns the rescue loop.  Without a
	# dropbear the operator's session is the only control channel, so it is
	# left attached.
	if [[ -n "${DROPBEAR_BIN:-}" ]]; then
		trap '' HUP
		for node in /dev/console /dev/ttyS0 /dev/tty0; do
			if [[ -e "$node" ]]; then
				exec <"$node" >"$node" 2>&1
				break
			fi
		done
	fi
	# Run the deployer as a child so the RAM bootstrap shell remains available
	# while the inner script freezes old userspace processes by name.
	/usr/bin/bash /run/deploy "$TARGET_DISK"
}

parse_args() {
	EXECUTE=0
	STAGE_TEST=0
	while (($#)); do
		case $1 in
			--image-url) IMAGE_URL=${2:?missing value for --image-url}; shift 2 ;;
			--image-file) IMAGE_FILE=${2:?missing value for --image-file}; shift 2 ;;
			--sha256) IMAGE_SHA256=${2:?missing value for --sha256}; shift 2 ;;
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
	check_dependencies
	discover_source
	discover_configuration
	if [[ "$IMAGE_FILE" == *.raw || "$IMAGE_URL" == *.raw ]]; then
		:
	else
		need_command unsquashfs
	fi
	prepare_image
	print_plan

	if (( STAGE_TEST )); then
		stage_bootstrap
		/usr/bin/bash -n "$BOOTSTRAP/run/deploy"
		umount -Rl "$BOOTSTRAP"
		printf '%s\n' 'STAGE-TEST: RAM bootstrap and inner deployer syntax are valid; no disk was changed.'
		return 0
	fi

	if (( ! EXECUTE )); then
		printf '%s\n' 'DRY-RUN: no disk, mount, service, or reboot operation was performed.'
		return 0
	fi
	[[ "${VPS2IMG_PIVOT_CONFIRM:-}" == "WIPE:$TARGET_DISK" ]] || \
		die "set VPS2IMG_PIVOT_CONFIRM=WIPE:$TARGET_DISK to allow the destructive operation"
	[[ "$SOURCE_DISK" == "$TARGET_DISK" ]] || warn 'target is not the current root disk; verify it before continuing'
	stage_bootstrap
	run_from_bootstrap
}

main "$@"
