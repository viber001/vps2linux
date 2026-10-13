# vps2linux

`vps2linux` 是一个从正在运行的 Linux 系统部署另一套 Linux raw image 的实验工具。

当前目标是验证 openSUSE Leap Micro SelfInstall raw image 在 PVE/Debian 环境中的安全替换流程。

## 设计原则

- 默认只做探测和 dry-run，不写磁盘。
- 只有同时提供 `--execute` 和 `VPS2LINUX_CONFIRM=WIPE:/dev/...` 才允许擦盘。
- 目标磁盘上的 LVM、ext4、EFI 和现有分区不能在运行态继续写入；脚本会把部署工具和 raw image 放入 RAM-backed bootstrap，再通过 `pivot_root` 离开旧系统。
- raw image 自带 EFI、BIOS 和 Btrfs root 分区；写入更大的目标盘后，脚本会用 raw image 的分区定义重建 GPT backup header，保留前三个分区的 GUID，并把 Btrfs root 扩展到 `--root-size-gib`，随后追加 Combustion 配置分区。
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

当前版本的执行路径已经在 VM 600 上验证：PVE `ext4+LVM` 可以从 RAM bootstrap 覆盖为 Leap Micro `EFI+Btrfs`，并通过 `efibootmgr` 创建 `vps2linux` 启动项；Combustion 首启已验证静态 IP 和 SSH 公钥登录。c49 的 PVE `Btrfs` root 已通过 dry-run 和 stage-test。

## 安全边界

该工具会删除目标磁盘上的全部数据。不要在没有控制台、独立救援介质或可回滚快照的机器上执行。执行前必须确认：

1. 目标设备是整个磁盘，而不是分区、LVM LV 或 loop device。
2. 所有目标分区已从独立 bootstrap 环境脱离挂载。
3. EFI 启动方式和 raw image 的启动文件已经在测试 VM 中验证。
4. SSH/BMC/串口控制台可用。

本项目采用 GPL-2.0-or-later。`master` 分支保留原始 vps2arch 备份；当前 `main` 是独立历史，用于 vps2linux 的后续开发。
