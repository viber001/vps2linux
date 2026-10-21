# The image also has EFI/BOOT/BOOTX64.EFI, but an explicit NVRAM entry avoids
# depending on firmware fallback behavior after replacing a previous OS.
if [[ -d /sys/firmware/efi ]]; then
	command -v efibootmgr >/dev/null 2>&1 || fail 'UEFI boot detected but efibootmgr is not staged'
	efibootmgr -c -d "$DISK" -p 2 -L '@PROGRAM@' -l '\EFI\BOOT\BOOTX64.EFI' || \
		fail 'efibootmgr could not create the @PROGRAM@ boot entry'
	efibootmgr -v || fail 'efibootmgr could not read the new boot entry'
else
	printf '%s\n' 'UEFI runtime unavailable; relying on the EFI fallback path or BIOS boot code.'
fi
