# 原版 vps2arch 的部署方法

本文记录上游项目 [vps2arch](https://gitlab.com/drizzt/vps2arch)（Timothy Redaelli）的实现原理，用于与本仓库的整盘 raw image 覆盖方案（`vps2img-pivot` / `vps2img-kexec`）对照。

- 上游仓库：<https://gitlab.com/drizzt/vps2arch>
- 本仓库的原始脚本保存在 `master` 分支：`vps2arch`（单文件 POSIX sh，约 370 行）。以下行号均指 `master:vps2arch`。

## 一句话概括

原版**不写磁盘镜像、不改分区**，而是在运行中的 VPS 上把根文件系统**原地替换成 Arch Linux**：先下载官方 bootstrap tarball 解压到 `/root.<arch>/`，在 chroot 里完成密钥与 fstab 准备；然后**删除 `/` 上除 bootstrap 目录和伪文件系统之外的所有文件**；再借助 bootstrap 自带的静态 `ld.so` 重新进入该目录，用 `pacstrap` 把 Arch 装到原根上；最后配置 bootloader、网络和 SSH。

README 里对这一步的自述是：

> How you wipe system without breaking everything? It's simple: using `ld.so` from *Bootstrap chroot* launch `chroot` tool. Since [you] erase all system directories except from the *Bootstrap chroot*, `/dev`, `/proc`, `/sys` and like, [the] only way [to] launch command inside the *Bootstrap chroot* [is] using ld.so from the *Bootstrap chroot* itself.

## 主流程

`master:vps2arch:356-367` 的调用顺序：

```sh
cd /
download_and_extract_bootstrap
configure_chroot
save_root_pass
backup_old_files
delete_all
install_packages
restore_root_pass
cleanup
configure_bootloader
configure_network
finalize
```

## 1. 下载并展开 bootstrap

`download_and_extract_bootstrap`（`master:vps2arch:53-77`）：

- 从 mirror 列表取 `iso/latest/sha256sums.txt`，从中挑出 `archlinux-bootstrap-<arch>.tar.zst` 的文件名并下载对应的 bootstrap 包。
- `grep -v archlinux-bootstrap-x86_64.tar.zst sha256sums.txt | sha256sum -c`：只校验 `sha256sums.txt` 里**除 bootstrap 自身之外**的条目，失败则 `exit 1`（bootstrap 包的哈希在这一步并未被真正核对，是本脚本的一处瑕疵）。
- `zstd -d -c ... | tar -xpf -` 解压到 `cd /` 后的 `/root.x86_64/`（目录名由 `$cpu_type` 决定）。
- 把宿主 `/etc/resolv.conf` 复制进去。
- 挂载 bootstrap 的 `proc` / `sysfs` / `devtmpfs` / `devpts` / `tmpfs`（`run`、`tmp`、`dev/shm`），挂载参数照抄 `arch-chroot`。
- 关键一步：`mount --bind / "/root.$cpu_type/mnt"`（`:66`）——把**当前根**绑定到 bootstrap 的 `/mnt`。这样后面即使 `/` 上的文件被删光，同一棵文件树仍然能通过 `/mnt` 访问。

## 2. 在 bootstrap chroot 里做前期配置

`chroot_exec`（`master:vps2arch:80-82`）仍然使用**旧系统磁盘上正常的 `chroot` 二进制**：

```sh
chroot_exec() {
	chroot "/root.$cpu_type" /bin/bash -c "$*"
}
```

此时旧系统完好，内核按 bootstrap 里 `/bin/bash` 的 PT_INTERP 使用 **bootstrap 自己的 `ld.so`**，与外层旧系统无关。`configure_chroot`（`:84-100`）在此环境中：

- 写入 mirrorlist；
- OpenVZ 下临时 `SigLevel = Never` 安装并启动 `haveged`（熵不足时 `pacman-key` 会卡住），随后恢复 `pacman.conf`；
- `pacman-key --init && pacman-key --populate archlinux`；
- 更新 `archlinux-keyring`；
- `genfstab /mnt >> /etc/fstab`（`/mnt` 就是 bind 过来的当前根）。

执行完就退出 chroot，外层仍是旧系统的 `sh`。

## 3. 保存需要跨删除保留的信息

- `save_root_pass`（`:102-106`）：把 `grep '^root:' /etc/shadow` 存到 `/root.$cpu_type/root.passwd`。
- `backup_old_files`（`:108-110`）：备份 `/etc/hostname`、`/etc/localtime` 到 bootstrap 的 `etc/`，失败用 `|| true` 忽略。

## 4. 删除旧系统（除 bootstrap 和伪文件系统）

`delete_all`（`master:vps2arch:111-118`）：

```sh
# Remove immutable flag from any files / directories
if command -v chattr >/dev/null 2>&1; then
	find / -type f \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' \
		-and ! -path '/selinux/*' -and ! -path "/root.$cpu_type/*" \) \
		-exec chattr -i {} + 2>/dev/null || true
fi
# Delete *all* files from /
find / \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' \
	-and ! -path '/selinux/*' -and ! -path "/root.$cpu_type/*" \) -delete 2>/dev/null || true
```

- 先对可能带 immutable 属性的文件 `chattr -i`。
- 排除 `/dev`、`/proc`、`/sys`、`/selinux` 和 `/root.$cpu_type/`，其余全部 unlink。
- 被删的是**目录项**，正在运行的 `sh`、它的 libc、以及所有已 mmap 的页面仍在内存中，所以脚本进程本身继续存活；但旧系统的 `ld.so`、`bash`、`libc` 的**磁盘文件已经不存在**。

要注意这**不是**“把 bash 复制进内存”之类的额外手段：bash 本来就在内存中运行，`find -delete` 只是让它失去磁盘依赖。

## 5. 借 bootstrap 的 ld.so 重新进入 chroot

`install_packages`（`master:vps2arch:120-138`）是整套方法的支点：

```sh
set -- "/root.$cpu_type/usr/lib"/ld-*.so.2
ld_so=$1

set -- base openssh reflector
is_openvz || set -- "$@" linux lvm2
[ "$bootloader" != "none" ] && set -- "$@" "$bootloader"
[ "$bootloader" = "syslinux" ] && set -- "$@" gptfdisk
[ -f /sys/firmware/efi/fw_platform_size ] && set -- "$@" efibootmgr
[ "$network" = "netctl" ] && set -- "$@" netctl
while read -r _ mountpoint filesystem _; do
	[ "$mountpoint" = "/" ] && [ "$filesystem" = "xfs" ] && packages="$packages xfsprogs"
done < /proc/mounts
# Black magic!
"$ld_so" --library-path "/root.$cpu_type/usr/lib" \
	"/root.$cpu_type/usr/bin/chroot" "/root.$cpu_type" /usr/bin/pacstrap -M /mnt "$@"
cp -L "/root.$cpu_type/etc/resolv.conf" /etc
```

为什么这样能成立：

1. **exec 的是 bootstrap 的 `ld.so`**。`ld-*.so.2` 是静态、自包含的 ELF，自身没有 PT_INTERP，所以内核装载它不需要任何磁盘上的旧解释器/库。旧系统的 `ld.so`、`libc` 这时已经被删掉，完全不参与。
2. **`--library-path` 指向 bootstrap 的 `/usr/lib`**，由这个 ld.so 自己去那里解析 libc 等依赖，而不是走默认路径。
3. **被装载的是 bootstrap 的 `/usr/bin/chroot`**，然后再 `chroot "/root.$cpu_type"` 执行 `pacstrap -M /mnt`（`-M` 表示不依赖 `/mnt/etc/mtab`）。
4. **`/mnt` 是第 1 步 bind 过来的原根**，所以 `pacstrap` 实际仍然安装到原来的根分区上；bootstrap 只当手术台。
5. 进程能继续跑到这一步，靠的是 Linux 的常规语义：`find -delete` 只移除目录项，运行中的进程及其已映射的可执行文件/共享库不受影响；`cd /`（`:356`）保证 cwd 永远有效，且所有路径都是绝对路径，不需要重新解析已删除的目录。

`pacstrap -M /mnt` 写入的包包括 `base`、`openssh`、`reflector`；非 OpenVZ 还会装 `linux`、`lvm2`，按需装 bootloader、`gptfdisk`、`efibootmgr`、`netctl`，以及 xfs 根时的 `xfsprogs`。

## 6. 恢复密码、清理 bootstrap

- `restore_root_pass`（`:140-149`）：原 root 密码未设置（`/etc/shadow` 中不是 `root:$...` 形式）时用 `echo "root:vps2arch" | chpasswd`，这与上游 README 的默认密码说明一致；否则把保存的 `root:` 行重新写回。
- `cleanup`（`:151-156`）：把 bootstrap 里生成的 `/etc/fstab` 移到 `/etc/fstab`，按 `/proc/mounts` 逆序 `umount -nl` 掉 bootstrap 的所有挂载，再 `rm -rf "/root.$cpu_type/"`。

此时 `/` 上已经是 Arch 的内容，但还没有引导配置和网络配置。

## 7. 配置 bootloader

`configure_bootloader`（`master:vps2arch:158-226`）：

- 用 `findmnt -no SOURCE /` 找根设备；若为 `/dev/mapper/*` 则记为需要 `lvm2`。
- EFI 检测：读 `/sys/firmware/efi/fw_platform_size`（`0` = BIOS，`64` = x86_64 UEFI）。
- LVM 时把 `lvm.conf` 的 `use_lvmetad = 1` 改为 `0`（兼容不使用 lvmetad 的发行版/卡在旧状态的源系统）。
- `grub`（默认）：
  - 若 `/proc/net/dev` 里仍是 `eth*` 接口名，在 `GRUB_CMDLINE_LINUX_DEFAULT` 加 `net.ifnames=0`；
  - 打开 `GRUB_TERMINAL_OUTPUT=console`；
  - LVM 时用 `lvs` 从 root LV 反查 VG，再用 `pvs` 得到底层 PV，`lsblk -npsro` 上溯到整盘并去重；
  - BIOS 对每块盘 `grub-install --target=i386-pc --recheck --force`，UEFI 用 `--target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB`；
  - `grub-mkconfig > /boot/grub/grub.cfg`；
  - LVM 时恢复 `lvm.conf`、在 mkinitcpio 的 `HOOKS` 里 `block` 之后插入 `lvm2`，并 `mkinitcpio -p linux`。
- `syslinux`：`syslinux-install_update -ami`，再把 `APPEND` 里的 `root=` 改成上溯出的整盘设备（LVM 时追加 VG/LV 信息）。
- OpenVZ/LXC 下 `-b none`，跳过 bootloader（容器没有引导）。

## 8. 配置网络与 SSH

`configure_network`（`master:vps2arch:228-267`）：

- 解析 `/proc/net/route` 找默认路由（`$2 == "00000000"`），用 `strtonum` 把小端十六进制网关转成点分十进制，取设备名与网关。
- 用 `ip addr show dev <dev>` 取所有 `inet` 地址。
- `systemd-networkd`：写 `/etc/systemd/network/default.network`（`[Match] Name=`、`[Network] Gateway=`、逐行 `Address=`），`systemctl enable systemd-networkd`。
- `netctl`：写 `/etc/netctl/default`（`Interface=`、`Connection=ethernet`、`IP=static`、`Address=(...)`，网关为 `0.0.0.0` 时写 `Routes=(0.0.0.0/0)`），`netctl enable default`。
- `systemctl enable sshd`。

`finalize`（`master:vps2arch:269-296`）：

- OpenVZ/Virtuozzo 7 下创建 `/etc/resolvconf/resolv.conf.d`；
- 取消注释 `#PermitRootLogin` 并设为 `yes`；
- `reflector -l 35 -p https --sort rate --save /etc/pacman.d/mirrorlist`；
- 打印提示：需要 `sync ; reboot -f` 粗暴重启，之后用旧 root 密码（或 `vps2arch`）SSH 登录。

## 参数与兼容性

`master:vps2arch:298-355` 的 `getopts`：

- `-b grub|syslinux|none`（默认 `grub`）
- `-n systemd-networkd|netctl|none`（默认 `systemd-networkd`）
- `-m mirror`（可重复，省略时从 archlinux.org 取 Worldwide HTTPS 列表）
- `-h` 帮助

容器检测：

- `is_openvz`：`[ -d /proc/vz ] && [ ! -d /proc/bc ]` → 强制 `bootloader=none`、`network=netctl`；
- `is_lxc`：`grep -aqw container=lxc /proc/1/environ` → 强制 `bootloader=none`。

## 与本仓库方案的关键差异

| 维度 | 原版 `vps2arch` | 本仓库 `vps2img-*` |
|---|---|---|
| 目标 | 把**当前根**原地替换为 Arch | 把另一套 Linux 的 **raw image 写到目标整盘** |
| 分区/GPT | 不动 | 重建 GPT、扩 root、加 Combustion 分区 |
| 脱离旧系统 | 不脱离；直接删旧文件后继续用同一内核/进程 | `pivot_root` 到 RAM tmpfs，或 `kexec` 换内核 |
| 旧 root 回写风险 | 不存在（旧 root 就是被覆盖对象） | pivot 需压制；kexec 后消失 |
| 依赖 | 官方 bootstrap tarball + 可用 mirror | 待部署 raw/SquashFS 镜像 + 独立救援通道 |
| 引导 | 在原根上重装 grub/syslinux | 使用 raw image 自带 EFI/BIOS 分区与启动项 |

理解原版的价值在于：它展示了“**删除全部旧文件后，只要还有一个在内存中运行的 shell 和一个不依赖旧磁盘的静态 `ld.so`，就仍能重建系统**”。本仓库的 `vps2img-pivot`/`vps2img-kexec` 之所以不采用这条路径，是因为要写入的是**整盘镜像**（会连 GPT 一起换掉），无法在旧根上原地进行，且必须排除旧内核/旧 systemd 的 async discard 与 writeback。
