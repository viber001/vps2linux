if [[ "$VERIFY_IMAGE" == 1 ]]; then
	printf 'image sha256:    %s (verification enabled)\n' "$IMAGE_SHA256"
else
	printf 'image sha256:    verification disabled (%s)\n' "${IMAGE_VERIFY_REASON:---no-verify-image}"
fi
