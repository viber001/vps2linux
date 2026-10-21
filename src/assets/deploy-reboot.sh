# Leave the machine up for a configurable number of seconds after the write
# finished. The disk is already final at this point, so the wait only gives the
# operator time to reconnect to the rescue SSH (pivot) or read the console
# before the reboot into the new system. Default 0 keeps the previous
# behaviour; `--reboot-delay 30` is the usual debugging value.
if (( ${REBOOT_DELAY:-0} > 0 )); then
	printf 'Rebooting in %s seconds; the target disk already holds the new image.\n' "$REBOOT_DELAY"
	remaining=$REBOOT_DELAY
	while (( remaining > 0 )); do
		sleep 1
		remaining=$((remaining - 1))
		if (( remaining > 0 && remaining % 10 == 0 )); then
			printf '%s seconds until reboot\n' "$remaining"
		fi
	done
fi
printf '%s\n' 'Raw image written. Rebooting into the new system.'
reboot -f
