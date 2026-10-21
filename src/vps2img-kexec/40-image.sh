
# detect_image_size reads the expected raw image size from the HTTP
# Content-Length header without downloading the body.
detect_image_size() {
	local url=$1 length
	if command -v curl >/dev/null 2>&1; then
		length=$(curl --fail --silent --show-error --head --location "$url" 2>/dev/null |
			awk 'BEGIN { IGNORECASE = 1 } /^content-length:/ { gsub(/\r/, ""); print $2; exit }')
	fi
	if [[ -z "$length" ]] && command -v wget >/dev/null 2>&1; then
		length=$(wget --spider --server-response "$url" 2>&1 |
			awk 'BEGIN { IGNORECASE = 1 } /Content-Length:/ { gsub(/\r/, ""); print $2; exit }')
	fi
	printf '%s' "$length"
}

# mem_available_bytes prints MemAvailable in bytes, or nothing when the kernel
# does not export it; the caller then stages on disk.
mem_available_bytes() {
	awk '/^MemAvailable:/ { printf "%d", $2 * 1024; exit }' /proc/meminfo 2>/dev/null
}

# last_used_end prints the last sector used by a partition on the disk, or 0
# when the disk has no partitions.  It reads sfdisk directly (table_field is
# only available inside the initramfs deploy heredoc, not here) and, like
# table_field, copes with sfdisk padding the value after the '='.
last_used_end() {
	local disk=$1
	sfdisk --dump "$disk" 2>/dev/null | awk -v disk="$disk" '
		function field(line, key,   m) {
			if (match(line, key "= *[^, ]+")) {
				m = substr(line, RSTART, RLENGTH)
				sub("^" key "= *", "", m)
				gsub(/,/, "", m)
				return m
			}
			return ""
		}
		index($0, disk) == 1 && /:/ {
			start = field($0, "start")
			size = field($0, "size")
			if (start ~ /^[0-9]+$/ && size ~ /^[0-9]+$/) {
				end = start + size - 1
				if (end > max) max = end
			}
		}
		END { printf "%d\n", max + 0 }
	'
}

# The GPT reserves the last 33 sectors (header plus entry array), so sfdisk
# reports last-lba = total_sectors - 34.
GPT_RESERVED_SECTORS=34
SCRATCH_ALIGN_SECTORS=2048

check_image_verification() {
	case "$VERIFY_IMAGE" in
		0) warn 'raw-image SHA-256 verification disabled by --no-verify-image' ;;
		1)
			[[ "$IMAGE_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || \
				die 'raw-image SHA-256 verification is enabled; pass a 64-hex --sha256 value or use --no-verify-image explicitly'
			IMAGE_SHA256=$(printf '%s' "$IMAGE_SHA256" | tr '[:upper:]' '[:lower:]')
			;;
		*) die "invalid image verification setting: $VERIFY_IMAGE (use 0 or 1)" ;;
	esac
}

resolve_image_mode() {
	case "$IMAGE_MODE_REQUEST" in
		stream|embed|disk)
			IMAGE_MODE=$IMAGE_MODE_REQUEST
			;;
		auto|'')
			if [[ -n "$IMAGE_URL" && "$IMAGE_URL" == *.raw ]]; then
				IMAGE_MODE=stream
			else
				# A SquashFS source is unpacked first, so a later step picks
				# embed or disk once the extracted size and free memory are known.
				IMAGE_MODE=auto
			fi
			;;
		*)
			die "invalid --image-mode: $IMAGE_MODE_REQUEST (use auto, stream, embed or disk)"
			;;
	esac
}

# plan_scratch_area computes, without touching the disk, the geometry of the
# ext4 scratch area that will sit past the last partition: SCRATCH_OFFSET and
# SCRATCH_BYTES.  It fails when the free space cannot hold the extracted image.
plan_scratch_area() {
	local raw_size=$1 total last_end start sectors avail wanted
	[[ -n "$TARGET_DISK" ]] || die 'disk mode needs --disk to name the target disk'
	total=$(blockdev --getsz "$TARGET_DISK")
	last_end=$(last_used_end "$TARGET_DISK")
	start=$(((last_end + 1 + SCRATCH_ALIGN_SECTORS - 1) / SCRATCH_ALIGN_SECTORS * SCRATCH_ALIGN_SECTORS))
	sectors=$((total - GPT_RESERVED_SECTORS - start))
	(( sectors > 0 )) || die "no free space at the end of $TARGET_DISK for a scratch area; use --image-mode embed"
	avail=$((sectors * 512))
	# The scratch area carries the raw image; the compressed archive stays on the
	# source filesystem, so the area needs the image plus ext4 metadata room.
	wanted=$((raw_size + 64 * 1048576))
	if (( SCRATCH_MIB > 0 )); then
		wanted=$((SCRATCH_MIB * 1048576))
	fi
	(( wanted <= avail )) || \
		die "the scratch area needs $wanted bytes but only $avail are free at the end of $TARGET_DISK; use --image-mode embed"
	sectors=$((wanted / 512))
	SCRATCH_OFFSET=$((start * 512))
	SCRATCH_BYTES=$((sectors * 512))
	printf 'Scratch area: %s MiB on %s at sector %s\n' \
		"$((sectors * 512 / 1048576))" "$TARGET_DISK" "$start"
}

# stage_image_on_disk formats the planned scratch area as ext4 through a loop
# device over the tail of the target disk and moves the extracted raw image onto
# it.  This is destructive (it overwrites the free space past the last
# partition), so it runs only for an execute run.  It deliberately does NOT add
# a GPT partition: the disk is in use, so the kernel cannot re-read the table,
# and the initramfs mounts the same area through a loop device at SCRATCH_OFFSET
# anyway.  The area sits above the raw image, so the copy-back from the head can
# never reach the scratch it reads from, and the final deploy rebuilds the GPT
# from the raw image.
stage_image_on_disk() {
	local loop scratch
	[[ -n "$DISK_RAW_SOURCE" && -s "$DISK_RAW_SOURCE" ]] || die 'the extracted image to stage is missing'
	printf 'Creating the %s MiB scratch area on %s at sector %s\n' \
		"$((SCRATCH_BYTES / 1048576))" "$TARGET_DISK" "$((SCRATCH_OFFSET / 512))"
	loop=$(losetup --find --show --offset "$SCRATCH_OFFSET" "$TARGET_DISK") || \
		die "cannot create a loop device for the scratch area on $TARGET_DISK"
	if ! mkfs.ext4 -F -q -L vps2img-scratch "$loop" >/dev/null 2>&1; then
		losetup -d "$loop"
		die 'cannot format the scratch area'
	fi
	scratch=$WORKDIR/scratch
	mkdir -p "$scratch"
	if ! mount "$loop" "$scratch"; then
		losetup -d "$loop"
		die 'cannot mount the scratch area'
	fi
	if ! mv -f "$DISK_RAW_SOURCE" "$scratch/image.raw" 2>/dev/null; then
		cp -f "$DISK_RAW_SOURCE" "$scratch/image.raw" || { umount "$scratch" || true; losetup -d "$loop"; die 'cannot copy the image onto the scratch area'; }
		rm -f "$DISK_RAW_SOURCE"
	fi
	sync
	umount "$scratch" || { losetup -d "$loop"; die 'cannot unmount the scratch area'; }
	losetup -d "$loop" || die 'cannot detach the scratch loop device'
	rmdir "$scratch" 2>/dev/null || true
	printf '%s\n' 'The raw image is staged on the target disk scratch area.'
}

prepare_image() {
	local archive raw_candidate extract raw_size mem_available
	mkdir -p "$WORKDIR"
	check_image_verification

	if [[ "$IMAGE_MODE" == stream ]]; then
		[[ -n "$IMAGE_URL" ]] || die 'stream mode requires --image-url pointing to a raw image'
		[[ "$IMAGE_URL" == *.raw ]] || die "cannot stream a non-raw URL: $IMAGE_URL"
		IMAGE_RAW_URL=$IMAGE_URL
		if [[ -z "$IMAGE_SIZE" ]]; then
			printf 'Querying image size: %s\n' "$IMAGE_URL"
			IMAGE_SIZE=$(detect_image_size "$IMAGE_URL")
		fi
		[[ "$IMAGE_SIZE" =~ ^[1-9][0-9]*$ ]] || \
			die 'cannot determine the raw image size from Content-Length; pass --image-size'
		RAW_SIZE=$IMAGE_SIZE
		return 0
	fi

	# embed, disk and auto all download and unpack the image on the source first.
	# The compressed source always lands on disk (never RAM); disk mode then
	# moves only the extracted raw image onto the scratch area.
	if [[ -n "$IMAGE_FILE" ]]; then
		[[ -f "$IMAGE_FILE" ]] || die "image file does not exist: $IMAGE_FILE"
		archive=$IMAGE_FILE
	else
		[[ -n "$IMAGE_URL" ]] || die 'provide --image-url (raw, streamed) or --image-file'
		archive="$WORKDIR/image.download"
		printf 'Downloading image: %s\n' "$IMAGE_URL"
		download_file "$IMAGE_URL" "$archive"
	fi

	if [[ "$archive" == *.raw ]]; then
		if [[ "$IMAGE_MODE" == disk ]]; then
			die 'disk mode needs a SquashFS source; use --image-mode stream or embed for a raw file'
		fi
		IMAGE_MODE=embed
		RAW_FILE="$WORKDIR/image.raw"
		[[ "$archive" == "$RAW_FILE" ]] || cp -f "$archive" "$RAW_FILE"
		[[ -s "$RAW_FILE" ]] || die 'the raw image is empty'
		RAW_SIZE=$(stat -c '%s' "$RAW_FILE")
		IMAGE_SIZE=$RAW_SIZE
		if [[ -n "$IMAGE_SHA256" ]]; then
			if [[ "$VERIFY_IMAGE" == 1 ]]; then
				printf '%s  %s\n' "$IMAGE_SHA256" "$RAW_FILE" | sha256sum -c -
			fi
		fi
		return 0
	fi

	need_command unsquashfs
	extract="$WORKDIR/extracted"
	rm -rf "$extract"
	mkdir -p "$extract"
	printf 'Unpacking image: %s\n' "$archive"
	unsquashfs -f -d "$extract" "$archive" >/dev/null
	raw_candidate=$(find "$extract" -type f -name '*.raw' -print -quit)
	[[ -n "$raw_candidate" ]] || die 'the image archive does not contain a .raw image'
	raw_size=$(stat -c '%s' "$raw_candidate")
	[[ "$raw_size" -gt 0 ]] || die 'the extracted raw image is empty'

	if [[ "$IMAGE_MODE" == auto ]]; then
		mem_available=$(mem_available_bytes)
		if [[ -n "$mem_available" ]] && (( mem_available >= raw_size + 536870912 )); then
			printf 'Staging in RAM: %s bytes free, image %s bytes\n' "$mem_available" "$raw_size"
			IMAGE_MODE=embed
		else
			printf '%s\n' 'Staging on the target disk: the extracted image does not fit the free memory.'
			IMAGE_MODE=disk
		fi
	fi

	if [[ "$IMAGE_MODE" == disk ]]; then
		# Plan the scratch geometry now (read-only), but move the image onto the
		# scratch partition only for an execute run, so a dry-run never touches
		# the target disk.
		plan_scratch_area "$raw_size"
		DISK_RAW_SOURCE=$raw_candidate
		RAW_SIZE=$raw_size
		IMAGE_SIZE=$raw_size
		if [[ "$VERIFY_IMAGE" == 1 ]]; then
			printf '%s  %s\n' "$IMAGE_SHA256" "$raw_candidate" | sha256sum -c -
		fi
		return 0
	fi

	# embed: move the extracted raw image next to the initramfs build tree.
	RAW_FILE="$WORKDIR/image.raw"
	rm -f "$RAW_FILE"
	mv -f "$raw_candidate" "$RAW_FILE"
	[[ -s "$RAW_FILE" ]] || die 'the extracted raw image is empty'
	RAW_SIZE=$(stat -c '%s' "$RAW_FILE")
	IMAGE_SIZE=$RAW_SIZE
	if [[ -n "$IMAGE_SHA256" && "$VERIFY_IMAGE" == 1 ]]; then
		printf '%s  %s\n' "$IMAGE_SHA256" "$RAW_FILE" | sha256sum -c -
	fi
}
