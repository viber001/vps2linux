# vps2linux

`vps2linux` 是一个从正在运行的 Linux 系统部署另一套 Linux raw image 的实验工具。

当前目标是验证 openSUSE Leap Micro SelfInstall raw image 在 PVE/Debian 环境中的安全替换流程。

## 使用背景

当前目标安装介质是：

```text
openSUSE-Leap-Micro.x86_64-6.2-Default-SelfInstall-Build12.9.install.iso
```

iVentoy 的 PXE 流程不直接支持这个 SelfInstall ISO，因此本项目采用间接方式：使用 iVentoy 提供的 EISO HTTP 内容获取安装介质中的 Leap Micro raw image，再由 `vps2linux` 从当前 Linux 的 RAM bootstrap 环境部署到目标整盘。

对应的 iVentoy EISO 目录是：

```text
http://10.68.247.14:16000/eiso/id/3/
```

该目录由 iVentoy 提供，镜像的具体 URL 和 SHA256 作为命令行参数传入，不在脚本中固定。

## 设计原则

- 默认只做探测和 dry-run，不写磁盘。
- 只有同时提供 `--execute` 和 `VPS2LINUX_CONFIRM=WIPE:/dev/...` 才允许擦盘。
- 目标磁盘上的 LVM、ext4、EFI 和现有分区不能在运行态继续写入；脚本会把部署工具和 raw image 放入 RAM-backed bootstrap，再通过 `pivot_root` 离开旧系统。
- raw image 自带 EFI、BIOS 和 Btrfs root 分区；写入更大的目标盘后，脚本会用 raw image 的分区定义重建 GPT backup header，保留前三个分区的 GUID，把 Btrfs root 扩展到 `--root-size-gib`，并把 Combustion 配置分区扩展到磁盘末尾。
- Leap Micro 的 KIWI 首启会把 root 分区扩到任意未分配空间，并在最后一个分区之后重建 `kiwi_RootPart`。如果 root 之后还留有空闲空间，首启就会搬走 root 分区、导致 root 文件系统失联（GRUB 报 `no such device`）。因此 Combustion 配置分区占据 root 之后的全部空间，使首启跳过重分区。
- 配置分区使用 `combustion` 文件系统标签和 `/combustion/script`；脚本写入 hostname、NetworkManager 静态 IPv4、DNS、root `authorized_keys` 和 SSH 公钥登录配置。PVE 的 `vmbrX` 会先解析到 bridge member，并保存 member 的设备名、`altname` 和 MAC；目标系统优先按 MAC 匹配，其次按保存的名称匹配，最后回退到第一个 `UP` 的非 loopback 网卡。
- PVE 单节点和 PVE 集群都只按普通 Debian/Linux root 环境检测，不修改 `/etc/pve` 集群配置。

## 当前用法

先执行只读计划：

```bash
./vps2linux \
  --image-url 'http://10.68.247.14:16000/eiso/id/3/openSUSE-Leap-Micro.raw.squashfs' \
  --sha256 '<raw-image-sha256>'
```

确认目标磁盘后才执行：

```bash
VPS2LINUX_CONFIRM=WIPE:/dev/sda \
  ./vps2linux --execute \
  --image-url 'http://10.68.247.14:16000/eiso/id/3/openSUSE-Leap-Micro.raw.squashfs' \
  --sha256 '<raw-image-sha256>' \
  --disk /dev/sda \
  --hostname c49 \
  --interface vmbr0 \
  --ipv4 10.68.247.225/24 \
  --gateway 10.68.247.199 \
  --dns 172.18.202.2 \
  --ssh-key-file /root/.ssh/authorized_keys
```

当前版本的执行路径已经在 VM 600 上验证：PVE `ext4+LVM` 可以从 RAM bootstrap 覆盖为 Leap Micro `EFI+Btrfs`，并通过 `efibootmgr` 创建 `vps2linux` 启动项；Combustion 首启已验证静态 IP 和 SSH 公钥登录。VM 602 的 PVE `Btrfs` root 也已完成端到端验证（400 GiB 目标盘、root 100 GiB、Combustion 填满剩余空间），首启后 hostname、静态 IPv4、SSH 公钥均由 Combustion 生效。

## vps2kexec（kexec + 自制 initramfs，方案 2）

`vps2kexec` 是独立的部署入口：在运行中的 Linux 源主机上构建一个最小 initramfs，用 `kexec` 切换到新内核，再由 initramfs 的 PID1 写入 raw image。与 `vps2linux` 的 `pivot_root` 不同，旧内核、旧 systemd 和旧 Btrfs 在 `kexec -e` 后完全消失，旧 root 的 async discard / writeback 不再可能覆盖刚写入的目标盘。

要求：

- 源主机已安装 `kexec-tools`、`busybox-static`、`cpio`、`gzip`、`squashfs-tools`、`gdisk`/`sgdisk`。
- Secure Boot 必须关闭：`/sys/kernel/security/lockdown` 中不能含 `[integrity]` 或 `[confidentiality]`，否则脚本直接退出。
- initramfs 使用内核内置驱动即可（ext4、virtio、squashfs、efivarfs 等），无需额外内核模块。
- `kexec -c -l` 使用 compat 系统调用（`kexec_load`），因为大 initramfs（约 1.5 GiB）在 `kexec_file_load` 下会以 `Cannot assign requested address` 失败。

raw image 可以随 initramfs 内嵌（`VPS2KEXEC_IMAGE_MODE=embed`，默认），或在 initramfs 内通过临时静态 IP 从 HTTP 下载并校验 SHA256（`VPS2KEXEC_IMAGE_MODE=net`）。

与 `vps2linux` 相同：默认只生成只读计划；破坏性执行必须同时提供 `--execute` 和环境变量 `VPS2KEXEC_CONFIRM=WIPE:<disk>`。`--stage-test` 只构建 initramfs 并 `kexec -l` 装载再卸载，不切换内核。

```bash
VPS2KEXEC_CONFIRM=WIPE:/dev/sda \
  ./vps2kexec --execute \
  --image-file /var/tmp/vps2kexec/image.raw \
  --sha256 "$RAW_IMAGE_SHA256" \
  --disk /dev/sda \
  --hostname pve1-leap-test \
  --interface vmbr0 \
  --ipv4 10.68.247.161/24 \
  --gateway 10.68.247.199 \
  --dns 172.18.202.2 \
  --ssh-key-file /root/.ssh/authorized_keys \
  --root-size-gib 40
```

执行路径已在 VM 600 上端到端验证：`kexec -e` 后 initramfs 重建 GPT、写入 image、创建 Combustion 分区，重启后由 `efibootmgr` 的 `vps2kexec` 启动项引导 Leap Micro，Combustion 首启生效（hostname、可预测网卡上的静态 IP、`authorized_keys`），且 Btrfs 无损坏。

## 安全边界

该工具会删除目标磁盘上的全部数据。不要在没有控制台、独立救援介质或可回滚快照的机器上执行。执行前必须确认：

1. 目标设备是整个磁盘，而不是分区、LVM LV 或 loop device。
2. 所有目标分区已从独立 bootstrap 环境脱离挂载。
3. EFI 启动方式和 raw image 的启动文件已经在测试 VM 中验证。
4. SSH/BMC/串口控制台可用。

本项目采用 GPL-2.0-or-later。`master` 分支保留原始 vps2arch 备份；当前 `main` 是独立历史，用于 vps2linux 的后续开发。
