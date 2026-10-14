#!/usr/bin/env bash
set -Eeuo pipefail

# vps2img-kexec - replace a running Linux installation with a raw Linux image by
# booting a self-made initramfs with kexec.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Plan 2 of vps2img-pivot.  The pivot_root bootstrap of vps2img-pivot cannot actually
# stop the old kernel from writing the target disk: old systemd, old btrfs
# async discard and old writeback keep touching the device after dd.  This
# script instead loads the running kernel plus a purpose-built initramfs with
# kexec and calls kexec -e, so the old kernel, systemd and btrfs are fully
# discarded before a single sector of the target disk is written.
#
# The generated initramfs is deliberately tiny: a static busybox, the staged
# deploy tools (sfdisk, sgdisk, losetup, mke2fs, partx, lsblk, findmnt,
# efibootmgr), a small dropbear sshd, bash and the deploy scripts.  The raw
# image is NOT carried in RAM.  By default it is streamed straight from an HTTP
# URL to the target disk inside the initramfs:
#
#   wget -O - <url> | dd of=<disk> bs=4M
#
# and then verified by reading the first Content-Length bytes back from the
# disk and comparing SHA-256.  This keeps the RAM footprint small enough for a
# real VPS.  Embedding the image inside the initramfs is still available as an
# explicit, RAM-heavy --image-mode embed opt-in.
#
# /init is PID 1; it brings up the network (matched by MAC), starts dropbear so
# a headless box can be debugged over SSH, streams and verifies the image, then
# runs /deploy, which rebuilds the GPT, creates the Combustion partition and the
# EFI boot entry.  On any failure it stays alive with SSH instead of dying.
#
# The destructive part keeps the same contract as vps2img-pivot: the default is a
# read-only plan, and writing requires both --execute and
# VPS2IMG_KEXEC_CONFIRM=WIPE:<disk>.

(#@DEFINE@) PROGRAM=vps2img-kexec
umask 077

PROGRAM=${0##*/}
WORKDIR=${VPS2IMG_KEXEC_WORKDIR:-/var/tmp/vps2img-kexec}
IMAGE_URL=${VPS2IMG_KEXEC_IMAGE_URL:-}
IMAGE_FILE=${VPS2IMG_KEXEC_IMAGE_FILE:-}
IMAGE_SHA256=${VPS2IMG_KEXEC_IMAGE_SHA256:-}
IMAGE_SIZE=${VPS2IMG_KEXEC_IMAGE_SIZE:-}
IMAGE_MODE_REQUEST=${VPS2IMG_KEXEC_IMAGE_MODE:-auto}
TARGET_DISK=${VPS2IMG_KEXEC_DISK:-}
TARGET_HOSTNAME=${VPS2IMG_KEXEC_HOSTNAME:-}
TARGET_INTERFACE=${VPS2IMG_KEXEC_INTERFACE:-}
TARGET_INTERFACE_NAMES=${VPS2IMG_KEXEC_INTERFACE_NAMES:-}
TARGET_MAC=${VPS2IMG_KEXEC_MAC:-}
TARGET_IPV4_CIDR=${VPS2IMG_KEXEC_IPV4_CIDR:-}
TARGET_GATEWAY=${VPS2IMG_KEXEC_GATEWAY:-}
TARGET_DNS=${VPS2IMG_KEXEC_DNS:-}
TARGET_USER=${VPS2IMG_KEXEC_USER:-root}
TARGET_PASSWORD=${VPS2IMG_KEXEC_PASSWORD:-}
SSH_KEY_FILE=${VPS2IMG_KEXEC_SSH_KEY_FILE:-/root/.ssh/authorized_keys}
ROOT_SIZE_GIB=${VPS2IMG_KEXEC_ROOT_SIZE_GIB:-64}
CONFIG_SIZE_MIB=${VPS2IMG_KEXEC_CONFIG_SIZE_MIB:-1024}
KEXEC_KERNEL=${VPS2IMG_KEXEC_KERNEL:-}
IMAGE_MODE=
IMAGE_RAW_URL=
RAW_FILE=
RAW_SIZE=
DROPBEAR_KEY=
DROPBEAR_BIN=
KEXEC_BIN=
TARGET_NIC_DRIVERS=
TARGET_DISK_DRIVERS=
KEXEC_METHOD=
KEXEC_LOCKDOWN=0
ROOT_SOURCE=
SOURCE_DISK=
STAGE=$WORKDIR/initramfs-root
INITRAMFS=$WORKDIR/initramfs.cpio.gz

# vps2img-kexec: where the deploy ramdisk's userspace comes from.  "host" (default)
# stages the running host's busybox and binaries.  "debian" fetches the Debian
# installer (d-i) netboot initrd plus the required .deb/.udeb packages over plain
# HTTP and assembles the ramdisk without ever touching the host package manager,
# so a non-apt source host (RHEL/openSUSE/...) can build it without preinstalling
# the deploy tools.  Either way kexec loads the RUNNING kernel, so only the
# userspace of the ramdisk is replaced.
RAMDISK_SOURCE=${VPS2IMG_KEXEC_RAMDISK_SOURCE:-host}
DI_MIRROR=${VPS2IMG_KEXEC_DI_MIRROR:-http://deb.debian.org/debian}
DI_SUITE=${VPS2IMG_KEXEC_DI_SUITE:-stable}
DI_ARCH=${VPS2IMG_KEXEC_DI_ARCH:-amd64}
DI_DEB_INDEX=$WORKDIR/di-index-deb.txt
DI_UDEB_INDEX=$WORKDIR/di-index-udeb.txt
declare -A DI_PKG_FILE=()
declare -A DI_PKG_DEP=()
declare -A DI_PKG_DISTS=()
declare -A DI_INDEX_PARSED=()
RESOLVED_DEBS=()

