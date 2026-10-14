
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

resolve_image_mode() {
	case "$IMAGE_MODE_REQUEST" in
		stream|embed)
			IMAGE_MODE=$IMAGE_MODE_REQUEST
			;;
		auto|'')
			if [[ -n "$IMAGE_URL" ]]; then
				if [[ "$IMAGE_URL" == *.raw ]]; then
					IMAGE_MODE=stream
				else
					die "cannot stream '$IMAGE_URL': only a raw image can be streamed; pass a raw .raw URL or use --image-mode embed (RAM-heavy)"
				fi
			elif [[ -n "$IMAGE_FILE" ]]; then
				IMAGE_MODE=embed
				warn 'streaming needs an HTTP raw URL; a local file must be embedded in the initramfs (RAM-heavy)'
			else
				die 'provide --image-url (raw, streamed) or --image-file'
			fi
			;;
		*)
			die "invalid --image-mode: $IMAGE_MODE_REQUEST (use auto, stream or embed)"
			;;
	esac
}

prepare_image() {
	local archive raw_candidate extract
	mkdir -p "$WORKDIR"

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
		[[ -n "$IMAGE_SHA256" ]] || warn 'no --sha256 given; the streamed image will not be verified'
		return 0
	fi

	# embed mode: materialise a raw file locally and carry it in the initramfs.
	if [[ -n "$IMAGE_FILE" ]]; then
		[[ -f "$IMAGE_FILE" ]] || die "image file does not exist: $IMAGE_FILE"
		archive=$IMAGE_FILE
	else
		[[ -n "$IMAGE_URL" ]] || die 'provide --image-url or --image-file'
		archive="$WORKDIR/image.download"
		printf 'Downloading image: %s\n' "$IMAGE_URL"
		download_file "$IMAGE_URL" "$archive"
	fi

	if [[ "$archive" == *.raw ]]; then
		RAW_FILE="$WORKDIR/image.raw"
		if [[ "$archive" != "$RAW_FILE" ]]; then
			cp -f "$archive" "$RAW_FILE"
		fi
	else
		need_command unsquashfs
		extract="$WORKDIR/extracted"
		rm -rf "$extract"
		mkdir -p "$extract"
		unsquashfs -f -d "$extract" "$archive" >/dev/null
		raw_candidate=$(find "$extract" -type f -name '*.raw' -print -quit)
		[[ -n "$raw_candidate" ]] || die 'the image archive does not contain a .raw image'
		RAW_FILE="$WORKDIR/image.raw"
		# Move instead of copy: the raw image is several GiB and the extracted
		# tree is on the same filesystem.
		rm -f "$RAW_FILE"
		mv -f "$raw_candidate" "$RAW_FILE"
	fi

	[[ -s "$RAW_FILE" ]] || die 'the extracted raw image is empty'
	RAW_SIZE=$(stat -c '%s' "$RAW_FILE")
	if [[ -n "$IMAGE_SHA256" ]]; then
		printf '%s  %s\n' "$IMAGE_SHA256" "$RAW_FILE" | sha256sum -c -
	fi
}

