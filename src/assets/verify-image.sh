check_image_verification() {
	case "$VERIFY_IMAGE" in
		0)
			IMAGE_VERIFY_REASON=--no-verify-image
			warn 'raw-image SHA-256 verification disabled by --no-verify-image'
			;;
		1)
			case "$IMAGE_SHA256" in
				auto|none)
					IMAGE_VERIFY_REASON="--sha256 $IMAGE_SHA256"
					warn "raw-image SHA-256 verification disabled by --sha256 $IMAGE_SHA256"
					IMAGE_SHA256=
					VERIFY_IMAGE=0
					;;
				*)
					[[ "$IMAGE_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || \
						die 'raw-image SHA-256 verification is enabled; pass a 64-hex --sha256 value, use --sha256 auto/none, or use --no-verify-image explicitly'
					IMAGE_SHA256=$(printf '%s' "$IMAGE_SHA256" | tr '[:upper:]' '[:lower:]')
					;;
			esac
			;;
		*) die "invalid image verification setting: $VERIFY_IMAGE (use 0 or 1)" ;;
	esac
}
