
# device_driver_modules prints the kernel module name of every driver in the
# parent chain of a sysfs device node. The module name is read from the driver's
# own module symlink, so it is the real module (sd -> sd_mod) rather than the
# driver name, and drivers built into the kernel (no module symlink) are skipped
# because the initramfs reuses the running kernel. The whole chain is captured
# because a physical machine needs the leaf driver, the transport and the host
# bus (for example sd_mod, virtio_scsi, virtio_pci), not only the first one.
device_driver_modules() {
	local node driver module
	node=$(readlink -f "$1" 2>/dev/null) || return 0
	while [[ -n "$node" && "$node" != / ]]; do
		if [[ -L "$node/driver" ]]; then
			driver=$(readlink -f "$node/driver")
			if [[ -L "$driver/module" ]]; then
				module=$(basename "$(readlink -f "$driver/module")")
				[[ -n "$module" ]] && printf '%s\n' "$module"
			fi
		fi
		node=$(dirname "$node")
	done
}

# interface_device_node prints a sysfs device path for a network interface,
# following bridge and bond masters down to the first member that has a device
# node. A PVE vmbrX, a bond, or a stacked bridge has no /device of its own, so
# without this the NIC driver would be missed on a physical host that bonds or
# bridges its management interface.
interface_device_node() {
	local name=$1 member
	while :; do
		if [[ -e "/sys/class/net/$name/device" ]]; then
			printf '%s\n' "/sys/class/net/$name/device"
			return 0
		fi
		member=$(ip -o link show master "$name" 2>/dev/null | awk -F': |@' 'NR == 1 { print $2; exit }')
		[[ -n "$member" ]] || return 1
		name=$member
	done
}

discover_configuration() {
	(#@INCLUDE@expand) src/assets/discover-network.sh
	# Capture the source NIC and storage driver modules so /init can modprobe
	# them on a physical machine whose kernel ships them as modules. The whole
	# driver chain is captured (virtio_net and virtio_pci; the storage leaf,
	# transport and host bus) because a physical machine needs all of them.
	if [[ -z "$TARGET_NIC_DRIVERS" ]]; then
		if nic_node=$(interface_device_node "$TARGET_INTERFACE"); then
			TARGET_NIC_DRIVERS=$(device_driver_modules "$nic_node" | sort -u | paste -sd ' ' -)
		fi
	fi
	if [[ -z "$TARGET_DISK_DRIVERS" ]]; then
		TARGET_DISK_DRIVERS=$(device_driver_modules "/sys/class/block/${TARGET_DISK##*/}/device" | sort -u | paste -sd ' ' -)
	fi
	(#@INCLUDE@expand) src/assets/validate-target.sh
}

detect_kernel() {
	[[ -n "$KEXEC_KERNEL" ]] || KEXEC_KERNEL=/boot/vmlinuz-$(uname -r)
	if [[ ! -r "$KEXEC_KERNEL" ]]; then
		KEXEC_KERNEL=$(ls -1 /boot/vmlinuz-* 2>/dev/null | tail -n 1)
	fi
	[[ -n "$KEXEC_KERNEL" && -r "$KEXEC_KERNEL" ]] || die 'cannot find a kernel image; set --kernel'
}

check_kexec_support() {
	local lockdown
	if ! KEXEC_BIN=$(command_path kexec); then
		KEXEC_BIN=
		# The host-side kernel switch still needs a kexec binary.  Debian mode
		# fetches kexec-tools over the configured Debian mirror in ensure_host_kexec instead of using
		# the host package manager; host mode requires it to be installed.
		[[ "$RAMDISK_SOURCE" == debian ]] || die 'required command is missing: kexec'
	fi
	[[ -r /sys/kernel/security/lockdown ]] || return 0
	lockdown=$(cat /sys/kernel/security/lockdown 2>/dev/null || true)
	case "$lockdown" in
		*'[integrity]'*|*'[confidentiality]'*)
			# Lockdown only denies the legacy kexec_load syscall. The
			# file-based kexec_file_load syscall is still allowed for a
			# kernel image the firmware trusts (the running, signed kernel),
			# so Secure Boot no longer has to be disabled.
			warn "kernel lockdown is active ($lockdown); using kexec_file_load (-s) with the running signed kernel"
			KEXEC_LOCKDOWN=1
			;;
	esac
}

print_plan() {
	local size_bytes disk_bytes model
	size_bytes=${RAW_SIZE:-0}
	disk_bytes=$(blockdev --getsize64 "$TARGET_DISK")
	model=$(lsblk -dnro MODEL "$TARGET_DISK" | sed 's/[[:space:]]*$//')
	printf '%s\n' '=== VPS2IMG_KEXEC PLAN ==='
	printf 'boot method:     kexec (%s)\n' "$KEXEC_KERNEL"
	printf 'ramdisk source:  %s\n' "$(ramdisk_source_description)"
	printf 'image mode:      %s\n' "$IMAGE_MODE"
	(#@INCLUDE@expand) src/assets/plan-base.sh
	if [[ "$IMAGE_MODE" == stream ]]; then
		printf 'image source:    %s (streamed to disk, %s bytes)\n' "$IMAGE_RAW_URL" "$size_bytes"
	elif [[ "$IMAGE_MODE" == disk ]]; then
		printf 'image source:    %s (unpacked on the source, staged on a %s MiB scratch area at the end of the target disk)\n' \
			"${IMAGE_URL:-$IMAGE_FILE}" "$(( ${SCRATCH_BYTES:-0} / 1048576 ))"
	else
	printf 'image source:    %s (embedded in initramfs, %s bytes)\n' "$RAW_FILE" "$size_bytes"
	fi
	if [[ "$VERIFY_IMAGE" == 1 ]]; then
		printf 'image sha256:    %s (verification enabled)\n' "$IMAGE_SHA256"
	else
		printf '%s\n' 'image sha256:    verification disabled (--no-verify-image)'
	fi
	(#@INCLUDE@expand) src/assets/plan-target.sh
	(#@INCLUDE@expand) src/assets/plan-disk.sh
	if [[ "$IMAGE_MODE" == embed ]]; then
		printf 'raw partition table:\n'
		sfdisk --dump "$RAW_FILE" 2>/dev/null || warn 'sfdisk could not print the raw image partition table'
	else
		printf '%s\n' 'The raw image GPT will be parsed from the target disk after streaming.'
	fi
	if [[ "$SOURCE_DISK" == "$TARGET_DISK" ]]; then
		printf '%s\n' 'The target is the current system disk; kexec discards the old root before writing.'
	else
		printf '%s\n' 'The target is different from the current system disk.'
	fi
}

check_dependencies() {
	local command_name archive
	for command_name in awk blockdev cp cpio find findmnt grep gzip lsblk mount readlink rm sha256sum sfdisk stat sync tar tr umount; do
		need_command "$command_name"
	done
	for command_name in hostname ip modinfo modprobe mountpoint paste sort; do
		need_command "$command_name"
	done
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		die 'curl or wget is required to download the configured image or Debian components'
	fi
	# The host ramdisk source stages the running host's tools, so it needs them
	# on the host.  The Debian source fetches every staged file over the configured
	# mirror, so
	# the host only needs the archive tooling above; kexec is prepared later by
	# ensure_host_kexec and never through the host package manager.
	if [[ "$RAMDISK_SOURCE" == host ]]; then
		for command_name in busybox dropbearkey sgdisk; do
			command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name (install it, or use --ramdisk-source auto or debian to fetch the tools)"
		done
	fi
	# embed and disk both unpack a SquashFS archive on the source host; only
	# stream copies a raw image straight through, so it needs neither.
	if [[ "$IMAGE_MODE" != stream ]]; then
		archive=${IMAGE_FILE:-$IMAGE_URL}
		if [[ "$archive" != *.raw ]]; then
			need_command unsquashfs
		fi
	fi
}

# ar_command returns an ar reader for .deb/.udeb members.  A minimal system
# may ship no ar at all (openSUSE Leap Micro has no binutils) and its busybox
# may lack the applet, so as a last resort download the static busybox the
# BusyBox project publishes, instead of forcing a package onto the host.
download_static_busybox() {
	local path=$WORKDIR/busybox-static
	if [[ ! -x "$path" ]]; then
		download_file "$STATIC_BUSYBOX_URL" "$path" >&2 || die "cannot download a static busybox from $STATIC_BUSYBOX_URL"
		chmod 0755 "$path"
	fi
	printf '%s\n' "$path"
}

ar_command() {
	if command -v ar >/dev/null 2>&1; then
		ar "$@"
	elif command -v busybox >/dev/null 2>&1 && [[ " $(busybox --list 2>/dev/null | tr '\n' ' ') " == *' ar '* ]]; then
		busybox ar "$@"
	else
		"$(download_static_busybox)" ar "$@"
	fi
}

# host_tool_commands lists the tools that only host mode needs on the host,
# beyond the base archive tooling that every mode requires.
host_tool_commands() {
	printf '%s\n' busybox dropbearkey kexec sgdisk
}

# host_tool_package maps a tool to the package that provides it, for --ramdisk-source apt.
host_tool_package() {
	case "$1" in
		busybox) printf 'busybox\n' ;;
		dropbearkey) printf 'dropbear\n' ;;
		kexec) printf 'kexec-tools\n' ;;
		sgdisk) printf 'gdisk\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

# missing_host_tools prints, one per line, the host-mode tools that are absent.
missing_host_tools() {
	local command_name
	for command_name in $(host_tool_commands); do
		command -v "$command_name" >/dev/null 2>&1 || printf '%s\n' "$command_name"
	done
}

# resolve_ramdisk_source turns the requested RAMDISK_SOURCE (auto, host, debian
# or apt) into the effective host or debian mode.  auto prefers the host when
# it already has every tool, otherwise it downloads; apt installs the missing
# tools through apt-get first and then stages the host.  A system with no
# package manager (openSUSE Leap Micro, for example) must use auto or debian.
resolve_ramdisk_source() {
	local command_name missing packages=()
	case "$RAMDISK_SOURCE" in
		host) ;;
		debian) ;;
		auto)
			missing=$(missing_host_tools)
			if [[ -z "$missing" ]]; then
				printf '%s\n' 'Ramdisk source: the host already provides every tool; staging the host.'
				RAMDISK_SOURCE=host
			else
				printf 'Ramdisk source: the host lacks %s; fetching the Debian installer components over HTTPS.\n' \
					"$(printf '%s ' $missing | sed 's/ $//')"
				RAMDISK_SOURCE=debian
			fi
			;;
		apt)
			command -v apt-get >/dev/null 2>&1 || \
				die '--ramdisk-source apt needs apt-get, which this host does not provide (use auto or debian to download instead)'
			missing=$(missing_host_tools)
			if [[ -z "$missing" ]]; then
				printf '%s\n' 'Ramdisk source: the host already provides every tool; staging the host.'
			else
				for command_name in $missing; do
					packages+=("$(host_tool_package "$command_name")")
				done
				printf 'Ramdisk source: installing the missing host tools with apt-get: %s\n' "${packages[*]}"
				# The update is best-effort: a host may have a repository that is
				# unreachable (an unsubscribed Proxmox host, for example) while the
				# packages we need are still installable from the cached indexes.
				DEBIAN_FRONTEND=noninteractive apt-get update || \
					warn 'apt-get update failed; installing from the existing package indexes'
				DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || die 'apt-get install failed'
			fi
			RAMDISK_SOURCE=host
			;;
		*)
			die "invalid --ramdisk-source: $RAMDISK_SOURCE (use auto, host, debian or apt)"
			;;
	esac
}


# module_names_to_stage lists every module the running (physical) machine has
# in use, plus the drivers and filesystems the deploy initramfs always needs.
# The running system is the target machine, so its in-use modules are exactly
# the drivers the kexec initramfs must load again.
module_names_to_stage() {
	{
		lsmod | awk 'NR > 1 { print $1 }'
		printf '%s\n' ${TARGET_NIC_DRIVERS:-} ${TARGET_DISK_DRIVERS:-} \
			loop ext4 vfat btrfs sd_mod scsi_mod
	} | awk 'NF' | sort -u
}

# stage_kernel_modules copies the .ko files for the in-use modules (with their
# full dependency closure) and the modprobe metadata into the initramfs, so the
# same kernel can bring the target hardware up after kexec on a physical host.
stage_kernel_modules() {
	local kver mod ko file modules_dir
	kver=$(uname -r)
	modules_dir=/lib/modules/$kver
	[[ -d "$modules_dir" ]] || { warn "no $modules_dir; not staging kernel modules"; return 0; }
	mkdir -p "$STAGE$modules_dir"
	declare -A seen=()
	while read -r mod; do
		[[ -n "$mod" ]] || continue
		while read -r ko; do
			[[ -n "$ko" && -f "$ko" ]] || continue
			[[ -n "${seen[$ko]:-}" ]] && continue
			seen[$ko]=1
			mkdir -p "$STAGE$(dirname "$ko")"
			cp -a "$ko" "$STAGE$ko"
		done < <(modprobe --show-depends "$mod" 2>/dev/null | awk '/^insmod / { print $2 }')
	done < <(module_names_to_stage)
	for file in modules.dep modules.dep.bin modules.alias modules.alias.bin \
		modules.softdep modules.builtin modules.builtin.bin modules.symbols modules.symbols.bin; do
		[[ -f "$modules_dir/$file" ]] || continue
		cp -a "$modules_dir/$file" "$STAGE$modules_dir/$file"
	done
}

# stage_firmware copies any firmware blobs the in-use modules request; some
# physical NICs and storage controllers need them before they initialise.
stage_firmware() {
	local mod fw candidate
	while read -r mod; do
		[[ -n "$mod" ]] || continue
		while read -r fw; do
			[[ -n "$fw" ]] || continue
			for candidate in "/lib/firmware/updates/$fw" "/lib/firmware/$fw" \
				"/lib/firmware/updates/$(uname -r)/$fw" "/lib/firmware/$(uname -r)/$fw"; do
				[[ -f "$candidate" ]] || continue
				mkdir -p "$STAGE$(dirname "$candidate")"
				cp -a "$candidate" "$STAGE$candidate"
			done
		done < <(modinfo -F firmware "$mod" 2>/dev/null)
	done < <(module_names_to_stage)
}

write_init() {
	cat > "$STAGE/init" <<'INIT'
#!/usr/bin/bash
set -u
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH
/bin/busybox --install -s /bin 2>/dev/null || true

log() {
	printf '[vps2img-kexec] %s\n' "$*"
	printf '[vps2img-kexec] %s\n' "$*" > /dev/kmsg 2>/dev/null || true
}

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /tmp /run /config /root/.ssh
mount -t devpts devpts /dev/pts 2>/dev/null || true

# PID1 must never exit: if it does (for example on an unbound variable), the
# kernel panics with "Attempted to kill init". Divert stderr to the kernel log
# so userspace errors reach the serial console, and trap EXIT into rescue().
exec 2>/dev/kmsg
# Debug: trace every command into the kernel log (visible on the serial console).
exec 8>/dev/kmsg
BASH_XTRACEFD=8
PS4='+${LINENO}: '
export PS4
set -x

# efivarfs is built into the running kernel; mount it so efibootmgr can create
# the firmware boot entry from inside the initramfs.
if [ -d /sys/firmware/efi ]; then
	mkdir -p /sys/firmware/efi/efivars
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || \
		log 'WARNING: cannot mount efivarfs; the EFI boot entry may be skipped'
fi

. /deploy.env

start_dropbear() {
	if [ -z "${DROPBEAR_BIN:-}" ] || [ ! -x "$DROPBEAR_BIN" ]; then
		log 'WARNING: dropbear is missing; SSH rescue is unavailable'
		return 0
	fi
	if [ -n "${DROPBEAR_KEY:-}" ]; then
		"$DROPBEAR_BIN" -s -r "$DROPBEAR_KEY" -p 22 -P /run/dropbear.pid >/dev/null 2>&1 || \
			log 'WARNING: dropbear failed to start'
	else
		"$DROPBEAR_BIN" -s -p 22 -P /run/dropbear.pid >/dev/null 2>&1 || \
			log 'WARNING: dropbear failed to start'
	fi
}

# bring_up_network matches the target NIC by MAC, because inside a bare
# initramfs there is no udev to apply the predictable interface names.
bring_up_network() {
	local path name address
	NET_IFACE=
	for path in /sys/class/net/*; do
		[ -r "$path/address" ] || continue
		name=${path##*/}
		[ "$name" = lo ] && continue
		address=$(tr 'A-Z' 'a-z' < "$path/address")
		if [ -n "${TARGET_MAC:-}" ] && [ "$address" = "$TARGET_MAC" ]; then
			NET_IFACE=$name
			break
		fi
		if [ -z "${NET_IFACE:-}" ]; then
			NET_IFACE=$name
		fi
	done
	if [ -z "${NET_IFACE:-}" ]; then
		log 'ERROR: no usable network interface found'
		return 1
	fi
	ip link set dev "$NET_IFACE" up 2>/dev/null || true
	if [ -n "${TARGET_IPV4_CIDR:-}" ]; then
		ip addr add "$TARGET_IPV4_CIDR" dev "$NET_IFACE" 2>/dev/null || true
	fi
	if [ -n "${TARGET_GATEWAY:-}" ]; then
		ip route add default via "$TARGET_GATEWAY" dev "$NET_IFACE" 2>/dev/null || true
	fi
	if [ -n "${TARGET_DNS:-}" ]; then
		printf 'nameserver %s\n' "$(printf '%s' "$TARGET_DNS" | tr ';' ' ')" > /etc/resolv.conf
	fi
	log "network up on $NET_IFACE (${TARGET_IPV4_CIDR:-no address})"
}

verify_image() {
	if [ "${VERIFY_IMAGE:-1}" != 1 ]; then
		log 'WARNING: image SHA-256 verification was explicitly disabled'
		return 0
	fi
	if [ -z "${IMAGE_SIZE:-}" ] || [ -z "${IMAGE_SHA256:-}" ]; then
		log 'ERROR: image size or checksum missing while verification is enabled'
		return 1
	fi
	log "verifying $IMAGE_SIZE bytes read back from $DISK"
	local actual
	if [ $((IMAGE_SIZE % 1048576)) -eq 0 ]; then
		actual=$(dd if="$DISK" bs=1M count=$((IMAGE_SIZE / 1048576)) 2>/dev/null | sha256sum | awk '{print $1}')
	else
		actual=$(head -c "$IMAGE_SIZE" "$DISK" | sha256sum | awk '{print $1}')
	fi
	log "image sha256 read back: $actual"
	if [ "$actual" != "$IMAGE_SHA256" ]; then
		log "ERROR: image checksum mismatch (expected $IMAGE_SHA256)"
		return 1
	fi
	log 'image checksum verified'
}

# write_image_disk copies the raw image out of the ext4 scratch area that the
# source host staged at the very END of the target disk.  The area sits above
# the image, so writing image.raw from the HEAD of the disk can never reach the
# scratch area it reads from.  Nothing is downloaded here: the image is already
# staged on the disk.
write_image_disk() {
	local loop scratch_bytes scratch_offset disk_bytes raw_path actual_size
	scratch_bytes=${SCRATCH_BYTES:-0}
	scratch_offset=${SCRATCH_OFFSET:-0}
	if [ "$scratch_bytes" -le 0 ] || [ "$scratch_offset" -le 0 ]; then
		log 'ERROR: disk mode needs a scratch area, but none was staged'
		return 1
	fi
	disk_bytes=$(( $(blockdev --getsz "$DISK") * 512 ))
	if [ $((scratch_offset + scratch_bytes)) -gt "$disk_bytes" ]; then
		log "ERROR: the staged scratch area runs past the end of $DISK"
		return 1
	fi
	loop=$(losetup --find --show --offset "$scratch_offset" "$DISK") || {
		log 'ERROR: cannot create the scratch loop device'
		return 1
	}
	mkdir -p /scratch
	if ! mount -t ext4 "$loop" /scratch; then
		log 'ERROR: cannot mount the staged scratch area'
		losetup -d "$loop"
		return 1
	fi
	raw_path=/scratch/image.raw
	[ -s "$raw_path" ] || {
		log 'ERROR: the staged scratch area has no image.raw'
		umount /scratch
		losetup -d "$loop"
		return 1
	}
	actual_size=$(stat -c %s "$raw_path")
	log "writing the staged image ($actual_size bytes) to $DISK"
	if ! dd if="$raw_path" of="$DISK" bs=4M; then
		log 'ERROR: writing the staged image to the disk failed'
		umount /scratch
		losetup -d "$loop"
		return 1
	fi
	sync
	umount /scratch
	losetup -d "$loop"
	return 0
}

# write_image streams the raw image straight to the disk (no RAM buffer) or, in
# embed mode, copies the image carried inside this initramfs, or in disk mode
# stages it on the target disk. It never buffers the whole image in memory: the
# HTTP stream is piped into dd, so at most a few megabytes are in flight. Page
# cache grows while streaming but is reclaimable kernel memory, not an anonymous
# buffer holding the image.
write_image() {
	local wget_rc dd_rc
	if [ "${IMAGE_MODE:-stream}" = embed ]; then
		[ -s /image.raw ] || { log 'ERROR: embedded image is missing'; return 1; }
		log 'writing embedded image to disk'
		if ! dd if=/image.raw of="$DISK" bs=4M; then
			return 1
		fi
	elif [ "${IMAGE_MODE:-stream}" = disk ]; then
		write_image_disk || return 1
	else
		[ -n "${IMAGE_RAW_URL:-}" ] || { log 'ERROR: no image URL for streaming'; return 1; }
		log "streaming image to $DISK: $IMAGE_RAW_URL"
		# A watchdog so a stalled HTTP GET cannot wedge the box; when it fires,
		# dd sees EOF and write_image fails into the rescue path (SSH stays up).
		timeout 1800 wget -O - "$IMAGE_RAW_URL" | dd of="$DISK" bs=4M
		# Save PIPESTATUS in one step: any assignment resets PIPESTATUS, so
		# reading it twice (${PIPESTATUS[0]} then ${PIPESTATUS[1]}) would make
		# the second read unbound under set -u.
		pipe_status=("${PIPESTATUS[@]}")
		wget_rc=${pipe_status[0]}
		dd_rc=${pipe_status[1]}
		if [ "$wget_rc" -ne 0 ] || [ "$dd_rc" -ne 0 ]; then
			log "ERROR: streaming failed (wget=$wget_rc dd=$dd_rc)"
			return 1
		fi
	fi
	sync
	verify_image
}

rescue() {
	log 'RESCUE: automatic deploy did not finish; staying alive'
	log 'RESCUE: SSH (dropbear, root pubkey) is available on port 22'
	log 'RESCUE: a console shell is attached below as well'
	for tty in /dev/tty0 /dev/ttyS0; do
		[ -e "$tty" ] || continue
		setsid sh -i <"$tty" >"$tty" 2>&1 &
	done
	while :; do
		if [ -f /run/dropbear.pid ] && kill -0 "$(cat /run/dropbear.pid)" 2>/dev/null; then
			:
		else
			start_dropbear
		fi
		sleep 30
	done
}

trap 'printf "[vps2img-kexec] init exiting rc=%s\n" "$?" > /dev/kmsg 2>/dev/null; rescue' EXIT
log "kexec initramfs is up, kernel $(uname -r)"
log "target disk ${DISK:-unknown}, image mode ${IMAGE_MODE:-stream}"

# Load the drivers the running hardware used, so kexec brings up the network and
# storage on a physical machine whose kernel ships them as modules. On a kernel
# that builds them in, these calls are harmless no-ops.
load_required_modules() {
	local mod
	# Coldplug through busybox mdev (in place of the udev a bare initramfs does
	# not have): the modalias rule lets the kernel autoload present devices.
	if command -v mdev >/dev/null 2>&1; then
		printf '%s\n' '$MODALIAS=.* 0:0 0660 @modprobe $MODALIAS' > /etc/mdev.conf
		mdev -s 2>/dev/null || true
	fi
	for mod in loop ext4 vfat sd_mod scsi_mod ${TARGET_DISK_DRIVERS:-} ${TARGET_NIC_DRIVERS:-}; do
		[ -n "$mod" ] || continue
		modprobe "$mod" 2>/dev/null && log "loaded module $mod" || true
	done
}
load_required_modules

bring_up_network || log 'WARNING: network bring-up failed; streaming may fail'
start_dropbear

# Log MemAvailable periodically so the streaming run can be shown not to hold
# the image in RAM. Kernel-page-cache writes are reclaimable; a real buffer
# would show MemAvailable collapsing.
(
	while :; do
		awk '/MemAvailable/ { printf "[vps2img-kexec] MemAvailable=%s kB\n", $2 }' /proc/meminfo > /dev/kmsg 2>/dev/null || true
		sleep 20
	done
) &

if write_image; then
	log 'running deployer'
	if /usr/bin/bash /deploy "$DISK" >/dev/kmsg 2>&1; then
		log 'deployer returned 0 without rebooting; entering rescue'
	else
		log "deployer failed with status $?; entering rescue"
	fi
else
	log 'image write or verification failed; entering rescue'
fi
rescue
INIT
	chmod 0755 "$STAGE/init"
}

write_deploy() {
	cat > "$STAGE/deploy" <<'DEPLOY'
#!/usr/bin/bash
set -Eeuo pipefail

DISK=${1:?target disk is required}
. /deploy.env

AUTHORIZED_KEYS=$(cat /authorized_keys)

fail() {
	printf 'FATAL: %s\n' "$*" >&2
	printf 'FATAL: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
	exit 1
}

flush_disk() {
	sync
	blockdev --flushbufs "$DISK" || fail "cannot flush pending writes for $DISK"
}

printf '%s\n' '=== VPS2IMG_KEXEC INITRAMFS DEPLOYMENT ==='
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fail "not a whole disk: $DISK"
flush_disk

for node in $(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" { print $1 }'); do
	[[ -z "$(findmnt -rn -S "$node" || true)" ]] || fail "target partition is still mounted: $node"
done
