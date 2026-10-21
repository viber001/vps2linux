
prepare_image() {
	local archive raw_candidate
	mkdir -p "$WORKDIR"
	case "$VERIFY_IMAGE" in
		0) warn 'raw-image SHA-256 verification disabled by --no-verify-image' ;;
		1)
			[[ "$IMAGE_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || \
				die 'raw-image SHA-256 verification is enabled; pass a 64-hex --sha256 value or use --no-verify-image explicitly'
			IMAGE_SHA256=$(printf '%s' "$IMAGE_SHA256" | tr '[:upper:]' '[:lower:]')
			;;
		*) die "invalid image verification setting: $VERIFY_IMAGE (use 0 or 1)" ;;
	esac

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
		local extract="$WORKDIR/extracted"
		rm -rf "$extract"
		mkdir -p "$extract"
		unsquashfs -f -d "$extract" "$archive" >/dev/null
		raw_candidate=$(find "$extract" -type f -name '*.raw' -print -quit)
		[[ -n "$raw_candidate" ]] || die 'the image archive does not contain a .raw image'
		RAW_FILE="$WORKDIR/image.raw"
		cp -f "$raw_candidate" "$RAW_FILE"
	fi

	[[ -s "$RAW_FILE" ]] || die 'the extracted raw image is empty'
	if [[ -n "$IMAGE_SHA256" && "$VERIFY_IMAGE" == 1 ]]; then
		printf '%s  %s\n' "$IMAGE_SHA256" "$RAW_FILE" | sha256sum -c -
	fi
}
