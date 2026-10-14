
usage() {
	cat <<EOF
Usage: $PROGRAM [options]

Discover and replace the current Linux installation with a raw image.
The default action is a read-only plan.  --execute requires an exact
VPS2IMG_PIVOT_CONFIRM value before any disk is written.

Options:
  --image-url URL       Raw image or SquashFS URL
  --image-file FILE     Local raw image or SquashFS file
  --sha256 HASH         Expected SHA-256 of the raw image
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
  --execute             Enter the RAM bootstrap and write the target disk
  --dry-run             Print the plan without staging or changing anything
  --stage-test          Stage the RAM bootstrap and syntax-check its deployer
  -h, --help            Show this help

Examples:
  $PROGRAM --image-url http://10.68.247.14:16000/eiso/id/3/openSUSE-Leap-Micro.raw.squashfs
  VPS2IMG_PIVOT_CONFIRM=WIPE:/dev/sda $PROGRAM --execute \\
    --image-file /run/leap-micro.raw --disk /dev/sda

The configuration partition uses the Leap Micro Combustion contract:
filesystem label "combustion" and /combustion/script. It is not a generic
cloud-init disk; the script writes hostname, networking and root SSH keys.
EOF
}

