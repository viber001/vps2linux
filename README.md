# vps2img-pivot / vps2img-kexec

`vps2img-pivot` 与 `vps2img-kexec` 是两个从正在运行的 Linux 系统部署另一套 Linux raw image 到目标整盘的实验工具。

当前目标是验证 openSUSE Leap Micro SelfInstall raw image 在 PVE/Debian 环境中的安全替换流程。

- `vps2img-pivot`：用 `pivot_root` 离开旧系统，在 RAM-backed bootstrap 中写盘（旧系统仍存活，需要轻量缓解）。
- `vps2img-kexec`：用 `kexec` 切换到新内核，由自制 initramfs 写盘（旧系统完全消失，推荐）。

## 使用背景

当前目标安装介质是：

```text
openSUSE-Leap-Micro.x86_64-6.2-Default-SelfInstall-Build12.9.install.iso
```

iVentoy 的 PXE 流程不直接支持这个 SelfInstall ISO，因此本项目采用间接方式：使用 iVentoy 提供的 EISO HTTP 内容获取安装介质中的 Leap Micro raw image，再由 `vps2img-pivot` 从当前 Linux 的 RAM bootstrap 环境部署到目标整盘。

对应的 iVentoy EISO 目录是：

```text
http://10.68.247.14:16000/eiso/id/3/
```

该目录由 iVentoy 提供，镜像的具体 URL 和 SHA256 作为命令行参数传入，不在脚本中固定。

## 设计原则

- 默认只做探测和 dry-run，不写磁盘。
- 只有同时提供 `--execute` 和 `VPS2IMG_PIVOT_CONFIRM=WIPE:/dev/...` 才允许擦盘。
- 目标磁盘上的 LVM、ext4、EFI 和现有分区不能在运行态继续写入；脚本会把部署工具和 raw image 放入 RAM-backed bootstrap，再通过 `pivot_root` 离开旧系统。
- raw image 自带 EFI、BIOS 和 Btrfs root 分区；写入更大的目标盘后，脚本会用 raw image 的分区定义重建 GPT backup header，保留前三个分区的 GUID，把 Btrfs root 扩展到 `--root-size-gib`，并把 Combustion 配置分区扩展到磁盘末尾。
- Leap Micro 的 KIWI 首启会把 root 分区扩到任意未分配空间，并在最后一个分区之后重建 `kiwi_RootPart`。如果 root 之后还留有空闲空间，首启就会搬走 root 分区、导致 root 文件系统失联（GRUB 报 `no such device`）。因此 Combustion 配置分区占据 root 之后的全部空间，使首启跳过重分区。
- 配置分区使用 `combustion` 文件系统标签和 `/combustion/script`；脚本写入 hostname、NetworkManager 静态 IPv4、DNS、root `authorized_keys` 和 SSH 公钥登录配置。PVE 的 `vmbrX` 会先解析到 bridge member，并保存 member 的设备名、`altname` 和 MAC；目标系统优先按 MAC 匹配，其次按保存的名称匹配，最后回退到第一个 `UP` 的非 loopback 网卡。
- PVE 单节点和 PVE 集群都只按普通 Debian/Linux root 环境检测，不修改 `/etc/pve` 集群配置。

## 两个入口对比

两个脚本都是破坏性、默认 dry-run 的整盘覆盖工具，区别在于如何脱离旧系统（详见文末各节）。

| 维度 | `vps2img-pivot` | `vps2img-kexec`（推荐） |
|---|---|---|
| 脱离旧系统 | `pivot_root` 到 RAM tmpfs bootstrap | `kexec -e` 切换内核，由自制 initramfs 的 PID1 写盘 |
| 旧内核 / systemd / Btrfs | 仍存活，需 `nodiscard` + `fsfreeze` + `blockdev --setro` + `umount -Rl` 压制回写 | `kexec -e` 后完全消失 |
| 旧 root 回写目标盘风险 | 有（只能缓解） | 无 |
| 镜像进入方式 | 整份 raw 复制进 RAM tmpfs | `stream` / `embed` / `disk`（见 `--image-mode`） |
| RAM 需求 | raw 大小 + ~1 GiB | `stream` 极小；`embed` 需放得下 raw；`disk` 中等 |
| `--image-mode` | 无 | `auto`（默认）/`stream`/`embed`/`disk` |
| `--ramdisk-source` | 无 | `auto`（默认）/`host`/`debian`/`apt` |
| Secure Boot | 不适用（不切换内核） | 默认 `kexec_file_load` 加载当前运行内核，可保持开启 |
| 用户配置 | `--user`/`--password`（默认 root/空） | `--user`/`--password`（默认 root/空） |
| 执行确认变量 | `VPS2IMG_PIVOT_CONFIRM=WIPE:<disk>` | `VPS2IMG_KEXEC_CONFIRM=WIPE:<disk>` |
| 构建产物规模 | 约 0.9 千行 | 约 2.0 千行 |

两者都需要 `--execute` 与各自的 `*_CONFIRM=WIPE:<disk>` 才能写盘，并共享 `src/lib/` 与 `src/assets/combustion-*.sh` 的公共代码。

## 当前用法

两个入口脚本 `vps2img-pivot` 与 `vps2img-kexec` 由 `src/` 片段经 `make`（`tools/build.py`）生成：

- 开发分支 `main` 只跟踪 `src/`、`tools/`、`Makefile` 与文档，构建产物被 `.gitignore` 忽略，使用前先 `make`。
- 发布分支 `dist` 直接提交构建好的脚本，克隆即可用，无需 `make`。

```bash
make            # 生成 ./vps2img-pivot 和 ./vps2img-kexec
make check      # 重建并做 bash -n 语法检查
```

先执行只读计划：

```bash
./vps2img-pivot \
  --image-url 'http://10.68.247.14:16000/eiso/id/3/openSUSE-Leap-Micro.raw.squashfs' \
  --sha256 '<raw-image-sha256>'
```

确认目标磁盘后才执行：

```bash
VPS2IMG_PIVOT_CONFIRM=WIPE:/dev/sda \
  ./vps2img-pivot --execute \
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

当前版本的执行路径已经在 VM 600 上验证：PVE `ext4+LVM` 可以从 RAM bootstrap 覆盖为 Leap Micro `EFI+Btrfs`，并通过 `efibootmgr` 创建 `vps2img-pivot` 启动项；Combustion 首启已验证静态 IP 和 SSH 公钥登录。VM 602 的 PVE `Btrfs` root 也已完成端到端验证（400 GiB 目标盘、root 100 GiB、Combustion 填满剩余空间），首启后 hostname、静态 IPv4、SSH 公钥均由 Combustion 生效。

## vps2img-kexec（kexec + 自制 initramfs，方案 2）

`vps2img-kexec` 是独立的部署入口：在运行中的 Linux 源主机上构建一个最小 initramfs，用 `kexec` 切换到新内核，再由 initramfs 的 PID1 写入 raw image。与 `vps2img-pivot` 的 `pivot_root` 不同，旧内核、旧 systemd 和旧 Btrfs 在 `kexec -e` 后完全消失，旧 root 的 async discard / writeback 不再可能覆盖刚写入的目标盘。

要求：

- 内核需支持 kexec（`kexec_load` 自 Linux 2.6.13，`kexec_file_load` 自 3.17）：物理机、KVM/Xen/HN 可用，容器（OpenVZ/LXC）不可用。
- 默认用 `kexec_file_load`（`kexec -s -l`）加载**当前正在运行的内核**，因此 **Secure Boot 可以保持开启**（lockdown 只禁止旧的 `kexec_load`）。仅当 `-s` 失败且系统未处于 lockdown 时才回退到 `kexec -c -l`；`--kernel` 指定未签名内核时仍需关闭 Secure Boot。
- ramdisk 用户态默认 `--ramdisk-source auto`：宿主工具齐全时 staging 宿主，否则经 HTTP 下载 d-i 组件组装。宿主至少需要 `cpio`、`gzip`、`gdisk`/`sgdisk`（`--image-mode stream` 直接流式写 raw image，不需要 `squashfs-tools`；`embed`/`disk` 对 SquashFS 源需要在宿主上有 `unsquashfs`）。详见下文。
- initramfs 按整条设备链收集在用驱动模块（`lsmod` + 目标磁盘/网卡驱动闭包）和固件，以便在物理机上启动；内核内置的驱动自动跳过。

默认 `--image-mode auto`：源是 raw URL 时用 `stream`，否则（SquashFS 源）解压后按可用内存选择 `embed` 或 `disk`。

- `stream`：initramfs 保持极小（busybox + 少量工具，几 MB），raw image 通过 HTTP 直接流式写入目标盘（`wget -O - <url> | dd of=<disk> bs=4M`），任何时候都不把整块 image 放进 RAM；随后从目标盘回读前 `--image-size` 字节做 SHA-256 校验（未给出 `--image-size` 时用 HTTP `Content-Length` 推导）。
- `embed`：在原系统解压 SquashFS，把整块 raw image 内嵌进 initramfs（内存 staging，非常耗内存，需确保内存放得下 raw image）。
- `disk`：在原系统解压 SquashFS，把 raw image 放到目标盘末尾的 ext4 scratch 区（盘尾空余空间内，不写 GPT 分区，用 loop 设备访问），initramfs 再从 scratch 拷回盘首写入。scratch 区位于 raw image 之上，写盘永远不会覆盖正在读取的 scratch；最终 deploy 会依据 raw image 重建 GPT，scratch 随之消失。压缩源始终先下载到磁盘，绝不落到内存。

`--scratch-mib N` 可覆盖 `disk` 模式的 scratch 区大小（默认用最后一个分区之后的全部空余空间）。磁盘 mode 已在 VM 602（400G 盘、4G 内存）端到端验证：`auto` 正确选择 `disk`，重启后为 `pve2-leap-test`（root 64G btrfs、combustion 分区、静态网络、`leap` wheel sudo/SSH 全部生效，Btrfs 无错误）。

Combustion 的 `/combustion/script` 会配置登录用户名、密码、SSH key、hostname、静态 IPv4/网关/DNS，并启用 `sshd` 和 `NetworkManager`。用户名通过 `--user` 指定（默认 `root`），密码通过 `--password` 指定（可选，设置后同时开启公钥和密码登录）。

与 `vps2img-pivot` 相同：默认只生成只读计划；破坏性执行必须同时提供 `--execute` 和环境变量 `VPS2IMG_KEXEC_CONFIRM=WIPE:<disk>`。`--stage-test` 只构建 initramfs 并 `kexec -l` 装载再卸载，不切换内核。

```bash
VPS2IMG_KEXEC_CONFIRM=WIPE:/dev/sda \
  ./vps2img-kexec --execute \
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

执行路径已在 VM 600 上端到端验证：`kexec -e` 后 initramfs 流式写入 image、重建 GPT 并创建直达磁盘末尾的 Combustion 分区（不留未分配空间，使 KIWI 首启跳过重分区），重启后由 `efibootmgr` 的 `vps2img-kexec` 启动项引导 Leap Micro；Combustion 首启生效（hostname、用户名/密码、静态 IP、`authorized_keys`），且首启后 Combustion 分区仍然存在、Btrfs 无损坏。VM 600/602 已在 Secure Boot 开启与关闭两种状态下验证通过。详见 `vps2img-kexec.md`。

### initramfs 用户态来源（`--ramdisk-source`）

部署 ramdisk 的用户态来源可选，按需选择：

- `auto`（默认）：宿主已具备全部所需工具时 staging 宿主（等价 `host`），否则自动改为经 HTTP 下载组装（等价 `debian`）。
- `host`：强制 staging 运行中的宿主（`busybox`/`dropbear`/`kexec`/`sgdisk` 等）；缺任一工具则报错。
- `debian`：强制从 Debian 安装器（d-i）的 netboot initrd 与普通 `.deb/.udeb` 经 HTTP 获取并自行组装，完全不经过宿主包管理器，适用于非 apt 源（如 openSUSE Leap Micro）。
- `apt`：先用 `apt-get` 补齐缺失的宿主工具，再 staging 宿主（仅 apt 宿主可用；`apt-get update` 失败仅告警，便于无订阅的 PVE 源）。

kexec 始终加载**正在运行的内核**，替换的只是 ramdisk 用户态，内核与模块始终匹配。

读 `.deb/.udeb` 需要 `ar`；若宿主没有 `ar`（如 Leap Micro 无 binutils），依次回退到宿主 busybox 的 `ar` applet、再回退到下载 busybox.net 发布的静态 busybox，因此无需任何宿主包。

`--di-mirror`（默认 `http://deb.debian.org/debian`）、`--di-suite`（默认 `stable`）、`--di-arch`（默认 `amd64`）选择 d-i 源。`debian`/`auto` 路径已在 openSUSE Leap Micro 源（无 apt、无 ar）上端到端验证，`apt` 路径已在 PVE Debian 源上验证。

```bash
VPS2IMG_KEXEC_CONFIRM=WIPE:/dev/sda \
  ./vps2img-kexec --execute --ramdisk-source debian \
  --image-url 'http://10.68.247.224:18080/openSUSE-Leap-Micro.raw' \
  --sha256 "$RAW_IMAGE_SHA256" \
  --disk /dev/sda --hostname pve2-leap-test --interface vmbr0 \
  --gateway 10.68.247.199 --ipv4 10.68.247.165/24 --dns 172.18.202.2 \
  --user leap --password '<password>' \
  --ssh-key-file /root/.ssh/authorized_keys --root-size-gib 100
```

`vps2img-pivot` 的 `pivot_root`（不使用 kexec）原理与研发测试过程见 `vps2img-pivot.md`。

## 安全边界

该工具会删除目标磁盘上的全部数据。不要在没有控制台、独立救援介质或可回滚快照的机器上执行。执行前必须确认：

1. 目标设备是整个磁盘，而不是分区、LVM LV 或 loop device。
2. 所有目标分区已从独立 bootstrap 环境脱离挂载。
3. EFI 启动方式和 raw image 的启动文件已经在测试 VM 中验证。
4. SSH/BMC/串口控制台可用。

本项目采用 GPL-2.0-or-later。`master` 分支保留原始 vps2arch 备份；当前 `main` 是独立历史，用于 vps2img-pivot 的后续开发。
