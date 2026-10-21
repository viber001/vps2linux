# Keep the image's BIOS and EFI partitions untouched, create the root partition
# from ROOT_SIZE_GIB and give everything that remains to the Combustion
# partition. GPT_SOURCE is the device (or raw image file) whose partition table
# is copied: reads come from the staged raw file or from the table just written
# to the target disk, depending on the deployer.
SECTOR_SIZE=$(sfdisk --dump "$GPT_SOURCE" 2>/dev/null | awk '/^sector-size:/ { print $2; exit }')
DISK_SECTORS=$(blockdev --getsz "$DISK")
RAW_TABLE=$(sfdisk --dump "$GPT_SOURCE" 2>/dev/null)
RAW_DISK_GUID=$(printf '%s\n' "$RAW_TABLE" | awk '/^label-id:/ { print $2; exit }')
RAW_P1_LINE=$(printf '%s\n' "$RAW_TABLE" | awk -v part="$(partition_path "$GPT_SOURCE" 1)" '$1 == part { print; exit }')
RAW_P2_LINE=$(printf '%s\n' "$RAW_TABLE" | awk -v part="$(partition_path "$GPT_SOURCE" 2)" '$1 == part { print; exit }')
RAW_P3_LINE=$(printf '%s\n' "$RAW_TABLE" | awk -v part="$(partition_path "$GPT_SOURCE" 3)" '$1 == part { print; exit }')
RAW_P1_START=$(table_field "$RAW_P1_LINE" start)
RAW_P1_SIZE=$(table_field "$RAW_P1_LINE" size)
RAW_P1_TYPE=$(table_field "$RAW_P1_LINE" type)
RAW_P1_UUID=$(table_field "$RAW_P1_LINE" uuid)
RAW_P2_START=$(table_field "$RAW_P2_LINE" start)
RAW_P2_SIZE=$(table_field "$RAW_P2_LINE" size)
RAW_P2_TYPE=$(table_field "$RAW_P2_LINE" type)
RAW_P2_UUID=$(table_field "$RAW_P2_LINE" uuid)
RAW_ROOT_START=$(table_field "$RAW_P3_LINE" start)
RAW_P3_TYPE=$(table_field "$RAW_P3_LINE" type)
RAW_P3_UUID=$(table_field "$RAW_P3_LINE" uuid)
[[ "$SECTOR_SIZE" =~ ^[0-9]+$ && "$RAW_ROOT_START" =~ ^[0-9]+$ ]] || fail 'cannot calculate the Combustion partition offset'
[[ -n "$RAW_DISK_GUID" && -n "$RAW_P1_START" && -n "$RAW_P1_SIZE" && -n "$RAW_P1_TYPE" && -n "$RAW_P1_UUID" && \
	-n "$RAW_P2_START" && -n "$RAW_P2_SIZE" && -n "$RAW_P2_TYPE" && -n "$RAW_P2_UUID" && \
	-n "$RAW_P3_TYPE" && -n "$RAW_P3_UUID" ]] || fail 'cannot read the raw image GPT metadata'
ROOT_SIZE_SECTORS=$((ROOT_SIZE_GIB * 1024 * 1024 * 1024 / SECTOR_SIZE))
ALIGN_SECTORS=$((1048576 / SECTOR_SIZE))
CONFIG_START=$((RAW_ROOT_START + ROOT_SIZE_SECTORS))
CONFIG_START=$(((CONFIG_START + ALIGN_SECTORS - 1) / ALIGN_SECTORS * ALIGN_SECTORS))
# openSUSE Leap Micro and other KIWI SelfInstall images grow the root partition
# to fill any unpartitioned space on the first boot and recreate kiwi_RootPart
# immediately after the last partition.  That would move our root partition and
# orphan the root filesystem.  Extend the Combustion partition to the end of the
# disk so no free space remains and the image's first-boot repartitioning is
# skipped.
CONFIG_SIZE=$((DISK_SECTORS - 34 - CONFIG_START))
(( CONFIG_SIZE >= CONFIG_SIZE_MIB * 1024 * 1024 / SECTOR_SIZE )) || \
	fail 'not enough free space for the Combustion partition'
CONFIG_END=$((CONFIG_START + CONFIG_SIZE - 1))
# The old kernel partition devices can survive the image write and keep sfdisk
# from replacing an in-use partition entry. Remove those stale mappings before
# writing the new on-disk GPT with sgdisk.
partx -d "$DISK" 2>/dev/null || true
sgdisk --zap-all "$DISK"
sgdisk \
	--disk-guid="$RAW_DISK_GUID" \
	--new=1:"$RAW_P1_START":"$((RAW_P1_START + RAW_P1_SIZE - 1))" \
	--typecode=1:"$RAW_P1_TYPE" --partition-guid=1:"$RAW_P1_UUID" --change-name=1:p.legacy \
	--new=2:"$RAW_P2_START":"$((RAW_P2_START + RAW_P2_SIZE - 1))" \
	--typecode=2:"$RAW_P2_TYPE" --partition-guid=2:"$RAW_P2_UUID" --change-name=2:p.UEFI \
	--new=3:"$RAW_ROOT_START":"$((RAW_ROOT_START + ROOT_SIZE_SECTORS - 1))" \
	--typecode=3:"$RAW_P3_TYPE" --partition-guid=3:"$RAW_P3_UUID" --change-name=3:p.lxroot \
	--new=4:"$CONFIG_START":"$CONFIG_END" \
	--typecode=4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 --change-name=4:combustion \
	"$DISK"
sync
sgdisk --verify "$DISK" || fail "the target GPT failed verification: $DISK"
ACTUAL_ROOT=$(sfdisk --dump "$DISK" | awk -v part="$(partition_path "$DISK" 3)" '$1 == part { gsub(/,/, "", $4); gsub(/,/, "", $6); print $4 " " $6; exit }')
[[ "$ACTUAL_ROOT" == "$RAW_ROOT_START $ROOT_SIZE_SECTORS" ]] || \
	fail "target GPT root partition mismatch: expected $RAW_ROOT_START/$ROOT_SIZE_SECTORS, got ${ACTUAL_ROOT:-missing}"
# Assert the Combustion partition exists and no >10 MiB hole is left: openSUSE
# Leap Micro's first boot (55kiwi-repart) relocates kiwi_RootPart and drops
# this partition whenever more than ~10 MiB of unpartitioned space is free.
ACTUAL_CONFIG=$(sfdisk --dump "$DISK" | awk -v part="$(partition_path "$DISK" 4)" '$1 == part { print $1 }')
[[ -n "$ACTUAL_CONFIG" ]] || fail 'the Combustion partition was not created'
LAST_USABLE=$((DISK_SECTORS - 34))
FREE_SECTORS=$((LAST_USABLE - CONFIG_END))
(( FREE_SECTORS * SECTOR_SIZE < 10 * 1024 * 1024 )) || \
	fail "target disk still has ${FREE_SECTORS} free sectors; Leap Micro would repartition it"
# Refresh the kernel's partition devices so the new root/Combustion partition
# nodes exist for the mount and losetup steps below.
partx -u "$DISK" 2>/dev/null || true
