
# sq renders a string as a single-quoted shell literal for safe interpolation
# into the generated Combustion script, escaping embedded single quotes.
sq() {
	printf "'%s'" "${1//\'/\'\\\'\'}"
}

usage() {
	cat <<EOF
Usage: $PROGRAM [options]

Boot the running kernel plus a small self-made initramfs with kexec, then
deploy a raw image to the target disk from that initramfs.  The old kernel,
systemd and filesystem are gone before the image is written.  By default the
raw image is streamed over HTTP directly to the target disk, so it never has to
fit in RAM.  The default action is a read-only plan; --execute requires an
exact VPS2IMG_KEXEC_CONFIRM value.

Options:
  --image-url URL       Raw image URL (default: streamed to the target disk).
                        A .squashfs URL needs disk or embed mode.
  --image-file FILE     Local raw image or SquashFS file (used with embed mode)
  --sha256 HASH         Expected SHA-256 of the raw image
  --image-size BYTES    Expected raw image size; auto-detected from the HTTP
                        Content-Length when omitted (stream mode)
  --disk DEVICE         Target whole disk (default: disk containing /)
  --hostname NAME       Hostname written by Combustion
  --interface NAME      Source/default network interface
  --ipv4 CIDR           Static IPv4 address, for example 10.0.0.20/24
  --gateway ADDRESS     IPv4 gateway written by Combustion
  --dns ADDRESS         DNS server(s), separated by commas or semicolons
  --user NAME           Login user created by Combustion (default: root)
  --password VALUE      Password for --user; when set, password SSH login is
                        enabled as well as the SSH key
  --ssh-key-file FILE   authorized_keys source (default: /root/.ssh/authorized_keys)
  --root-size-gib N     Btrfs partition size (default: 64)
  --config-size-mib N   Minimum Combustion partition size (default: 1024);
                        the partition is extended to the end of the disk
  --kernel FILE         Kernel image loaded with kexec (default: /boot/vmlinuz-\$(uname -r))
  --ramdisk-source SRC  Where the deploy ramdisk userspace comes from:
                        auto (default): stage the running host's tools when the
                        host already has them all, otherwise download the Debian
                        installer (d-i) components over HTTP;
                        host: force the host tools, fail if any are missing;
                        debian: force the HTTP download, needing no host package
                        manager (for a non-apt source host such as Leap Micro);
                        apt: install the missing host tools with apt-get, then
                        stage the host (apt-based hosts only)
  --di-mirror URL       Debian mirror for the installer components
                        (default: http://deb.debian.org/debian)
  --di-suite NAME       Debian suite the installer components come from
                        (default: stable)
  --di-arch NAME        Debian architecture (default: amd64)
  --image-mode MODE     auto (default), stream, embed or disk.
                        stream: fetch the raw image over HTTP straight to disk;
                        embed:  unpack on the source, then carry the image inside
                                the initramfs (RAM staging);
                        disk:   unpack on the source, then stage the image on an
                                ext4 scratch area at the end of the target disk
                                and copy it back out from the initramfs;
                        auto:   stream for a raw URL, otherwise embed when the
                                free memory fits the image and disk when it does
                                not.  The compressed source is always downloaded
                                to disk first, never to RAM.
  --scratch-mib N       Scratch area for disk mode, at the end of the target
                        disk (default: all the free space after the last
                        partition); must exceed the extracted raw image
  --execute             Load the initramfs with kexec and switch kernels
  --dry-run             Print the plan without staging or changing anything
  --stage-test          Build the initramfs, syntax-check its scripts and
                        kexec -l / kexec -u without switching kernels; this
                        works under Secure Boot via kexec_file_load (-s)
  -h, --help            Show this help

Examples:
  # Recommended: stream a raw image from HTTP (low RAM)
  VPS2IMG_KEXEC_CONFIRM=WIPE:/dev/sda $PROGRAM --execute \\
    --image-url http://10.68.247.224:18080/openSUSE-Leap-Micro.raw \\
    --sha256 <raw-image-sha256> --disk /dev/sda \\
    --hostname target --user leap --password '<password>' \\
    --ipv4 192.0.2.20/24 --gateway 192.0.2.1 --dns 192.0.2.53

  $PROGRAM --stage-test \\
    --image-url http://10.68.247.224:18080/openSUSE-Leap-Micro.raw

The configuration partition uses the Leap Micro Combustion contract:
filesystem label "combustion" and /combustion/script. It is not a generic
cloud-init disk; the script writes the user, password, hostname, networking
and SSH keys.
EOF
}

