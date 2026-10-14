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

## vps2leapmicro（kexec + 自制 initramfs，方案 2）

`vps2leapmicro` 是独立的部署入口：在运行中的 Linux 源主机上构建一个最小 initramfs，用 `kexec` 切换到新内核，再由 initramfs 的 PID1 写入 raw image。与 `vps2linux` 的 `pivot_root` 不同，旧内核、旧 systemd 和旧 Btrfs 在 `kexec -e` 后完全消失，旧 root 的 async discard / writeback 不再可能覆盖刚写入的目标盘。

要求：

- 源主机已安装 `kexec-tools`、`dropbear`、`busybox-static`、`cpio`、`gzip`、`gdisk`/`sgdisk`（`--image-mode stream` 直接流式写 raw image，不需要 `squashfs-tools`）。
- 内核需支持 kexec（`kexec_load` 自 Linux 2.6.13，`kexec_file_load` 自 3.17）：物理机、KVM/Xen/HN 可用，容器（OpenVZ/LXC）不可用。
- 默认用 `kexec_file_load`（`kexec -s -l`）加载**当前正在运行的内核**，因此 **Secure Boot 可以保持开启**（lockdown 只禁止旧的 `kexec_load`）。仅当 `-s` 失败且系统未处于 lockdown 时才回退到 `kexec -c -l`；`--kernel` 指定未签名内核时仍需关闭 Secure Boot。
- initramfs 按整条设备链收集在用驱动模块（`lsmod` + 目标磁盘/网卡驱动闭包）和固件，以便在物理机上启动；内核内置的驱动自动跳过。

默认 `--image-mode stream`：initramfs 保持极小（busybox + 少量工具，几 MB），raw image 通过 HTTP 直接流式写入目标盘（`wget -O - <url> | dd of=<disk> bs=4M`），任何时候都不把整块 image 放进 RAM；随后从目标盘回读前 `--image-size` 字节做 SHA-256 校验（未给出 `--image-size` 时用 HTTP `Content-Length` 推导）。`--image-mode embed` 把整块 image 内嵌进 initramfs，仅作为显式的非默认选项保留，非常耗内存。

Combustion 的 `/combustion/script` 会配置登录用户名、密码、SSH key、hostname、静态 IPv4/网关/DNS，并启用 `sshd` 和 `NetworkManager`。用户名通过 `--user` 指定（默认 `root`），密码通过 `--password` 指定（可选，设置后同时开启公钥和密码登录）。

与 `vps2linux` 相同：默认只生成只读计划；破坏性执行必须同时提供 `--execute` 和环境变量 `VPS2LEAPMICRO_CONFIRM=WIPE:<disk>`。`--stage-test` 只构建 initramfs 并 `kexec -l` 装载再卸载，不切换内核。

```bash
VPS2LEAPMICRO_CONFIRM=WIPE:/dev/sda \
  ./vps2leapmicro --execute \
  --image-url 'http://10.68.247.224:18080/openSUSE-Leap-Micro.raw' \
  --sha256 "$RAW_IMAGE_SHA256" \
  --disk /dev/sda \
  --hostname pve1-leap-test \
  --interface vmbr0 \
  --ipv4 10.68.247.161/24 \
  --gateway 10.68.247.199 \
  --dns 172.18.202.2 \
  --user leap --password '<password>' \
  --ssh-key-file /root/.ssh/authorized_keys \
  --root-size-gib 40
```

执行路径已在 VM 600 上端到端验证：`kexec -e` 后 initramfs 流式写入 image、重建 GPT 并创建直达磁盘末尾的 Combustion 分区（不留未分配空间，使 KIWI 首启跳过重分区），重启后由 `efibootmgr` 的 `vps2leapmicro` 启动项引导 Leap Micro；Combustion 首启生效（hostname、用户名/密码、静态 IP、`authorized_keys`），且首启后 Combustion 分区仍然存在、Btrfs 无损坏。VM 600/602 已在 Secure Boot 开启与关闭两种状态下验证通过。详见 `vps2leapmicro.md`。

`vps2linux` 的 `pivot_root`（不使用 kexec）原理与研发测试过程见 `vps2linux.md`。

## vps2ins（实验性）

`vps2ins` 是 `vps2leapmicro` 的一个**实验性**变体，部署逻辑完全相同（kexec、流式写盘、GPT 重建、Combustion、扩容、EFI 启动项），唯一区别是 **initramfs 用户态来源**：它默认从 Debian 安装器（d-i）组件经普通 HTTP 获取并自行组装 ramdisk，不依赖宿主的包管理器，因此也能在**非 apt 源**（RHEL/openSUSE）上构建。

```bash
VPS2INS_CONFIRM=WIPE:/dev/sda \
  ./vps2ins --execute \
  --image-url 'http://10.68.247.224:18080/openSUSE-Leap-Micro.raw' \
  --sha256 "$RAW_IMAGE_SHA256" \
  --disk /dev/sda --hostname pve2-leap-test --interface vmbr0 \
  --gateway 10.68.247.199 --ipv4 10.68.247.165/24 --dns 172.18.202.2 \
  --user leap --password '<password>' \
  --ssh-key-file /root/.ssh/authorized_keys --root-size-gib 100
```

可用 `--ramdisk-source host` 切回 `vps2leapmicro` 的“打包宿主二进制”行为，`--di-mirror/--di-suite/--di-arch` 选择 d-i 源。该路径尚未定型，默认请用 `vps2leapmicro`。

## 安全边界

该工具会删除目标磁盘上的全部数据。不要在没有控制台、独立救援介质或可回滚快照的机器上执行。执行前必须确认：

1. 目标设备是整个磁盘，而不是分区、LVM LV 或 loop device。
2. 所有目标分区已从独立 bootstrap 环境脱离挂载。
3. EFI 启动方式和 raw image 的启动文件已经在测试 VM 中验证。
4. SSH/BMC/串口控制台可用。

本项目采用 GPL-2.0-or-later。`master` 分支保留原始 vps2arch 备份；当前 `main` 是独立历史，用于 vps2linux 的后续开发。
