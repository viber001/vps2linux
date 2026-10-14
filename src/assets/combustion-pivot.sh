(#@INCLUDE@) src/assets/combustion-base.sh
mkdir -p "\$ROOT/etc/ssh/sshd_config.d"
cat > "\$ROOT/etc/ssh/sshd_config.d/90-vps2img-pivot.conf" <<'SSHD'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
SSHD

systemctl --root="\$ROOT" enable sshd.service
systemctl --root="\$ROOT" enable NetworkManager.service

# Mirror kernel and systemd output to the VGA console in addition to the serial
# console, so the boot is visible on the PVE web console even when the serial
# console is not attached. The image already carries console=tty0 in
# GRUB_CMDLINE_LINUX_DEFAULT, but its generated grub.cfg omitted it; patch the
# effective grub.cfg directly and update the bootloader defaults so later
# grub2-mkconfig runs keep the setting. Effective from the next boot.
if [[ -f "\$ROOT/boot/grub2/grub.cfg" ]] && ! grep -q 'console=tty0' "\$ROOT/boot/grub2/grub.cfg"; then
	sed -i 's/console=ttyS0,115200/console=ttyS0,115200 console=tty0/g' "\$ROOT/boot/grub2/grub.cfg"
fi
if [[ -f "\$ROOT/etc/default/grub" ]] && ! grep -q 'console=tty0' "\$ROOT/etc/default/grub"; then
	sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 console=tty0"/' "\$ROOT/etc/default/grub"
fi
if [[ -f "\$ROOT/etc/sysconfig/bootloader" ]] && ! grep -q 'console=tty0' "\$ROOT/etc/sysconfig/bootloader"; then
	sed -i 's/^\(DEFAULT_APPEND="[^"]*\)"/\1 console=tty0"/; s/^\(FAILSAFE_APPEND="[^"]*\)"/\1 console=tty0"/' "\$ROOT/etc/sysconfig/bootloader"
fi
