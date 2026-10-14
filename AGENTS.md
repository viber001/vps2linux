# vps2img-pivot 接手说明

## 项目目标

`vps2img-pivot` 用当前运行中的 Linux 作为 bootstrap，把另一套 Linux raw image 部署到整块目标盘。由于目标盘同时承载当前 root，部署工具和镜像必须先复制到独立的 RAM-backed bootstrap，再通过 `pivot_root` 脱离旧系统，最后覆盖目标盘。

这是一个破坏性实验工具，默认只执行探测和 dry-run。不要把它当作通用安装器或在线升级工具。

## 使用背景

当前项目用于间接部署：

```text
openSUSE-Leap-Micro.x86_64-6.2-Default-SelfInstall-Build12.9.install.iso
```

iVentoy 的 PXE 流程不直接支持这个 SelfInstall ISO，因此使用 iVentoy 提供的 EISO HTTP 内容取得其中的 Leap Micro raw image，再由当前 Linux 的 RAM bootstrap 部署到目标整盘。

iVentoy EISO 目录：

```text
http://10.68.247.14:16000/eiso/id/3/
```

镜像具体 URL 和 SHA256 应通过参数提供，不要把部署环境之外的地址固定到脚本逻辑中。

## 仓库约定

- 当前开发分支为 `main`。
- `master` 保留原始 `vps2arch` 备份，不要在 `master` 上开发。
- 主入口是 `vps2img-pivot`，用户文档是 `README.md`。
- 本地部署环境、地址、主机名、MAC、快照和访问方式放在被忽略的 `AGENTS.private.md`，不要提交或发布。

## 执行流程

脚本大致按以下阶段运行：

1. 识别当前 root、底层 whole disk、文件系统和网络接口。
2. 获取 raw image 或 SquashFS image，并校验 raw image SHA256。
3. 生成只读计划；只有 `--execute` 和精确的 `VPS2IMG_PIVOT_CONFIRM=WIPE:<disk>` 同时存在时才继续。
4. 创建独立 RAM tmpfs，复制所需二进制、动态库、镜像和配置。
5. 脱离目标盘上的非 root 挂载点，`pivot_root` 到 RAM bootstrap。
6. flush pending writes，冻结旧 userspace，尝试只读重挂旧 root 并严格卸载。
7. 写入 raw image，使用 `sgdisk` 重建目标盘 GPT，避免较大目标盘保留错误的 raw image backup GPT。
8. 创建 Combustion 配置分区，写入 hostname、静态网络、SSH public key 和服务启用配置。
9. 校验 GPT、EFI 启动项和 root 分区边界，flush writes 后重启。

## 支持的输入和目标布局

当前重点验证的是 PVE/Debian `ext4 + LVM` 或 Btrfs 源系统，以及 openSUSE Leap Micro `EFI + Btrfs` raw image。

脚本支持：

- raw image 或 SquashFS image 下载、解包和 SHA256 校验；
- PVE `vmbr*` 到 bridge member、MAC 和 predictable interface name 的映射；
- Leap Micro EFI/BIOS/Btrfs 分区保留和扩展；
- `sgdisk --verify` 以及 root partition start/size 双重校验；
- Combustion 配置分区；
- hostname、静态 IPv4、gateway、DNS、root `authorized_keys`；
- EFI NVRAM 启动项创建和 fallback EFI 路径。

默认目标布局：

```text
sda1  保留 raw image 的 BIOS 分区和 GUID
sda2  保留 raw image 的 EFI 分区和 GUID
sda3  Btrfs root，默认 `--root-size-gib`（64 GiB）
sda4  ext4，label=combustion，扩展到磁盘末尾，不留空闲空间
```

`sda4` 必须占据 root 之后的全部空间：Leap Micro 的 KIWI 首启会把 root 扩到任意空闲空间并在最后一个分区之后重建 `kiwi_RootPart`，留空闲空间会让首启搬走 root、导致 root 文件系统失联。`sda4` 使用 Leap Micro 的 Combustion 契约，不是通用 cloud-init 分区。配置文件为：

```text
/combustion/script
```

## 配置和测试

所有环境相关值都必须由调用者提供，不要把真实地址写入源码或公开文档：

```bash
./vps2img-pivot --dry-run \
  --image-file /path/to/leap-micro.raw \
  --sha256 "$RAW_IMAGE_SHA256" \
  --disk /dev/sdX \
  --hostname target-host \
  --interface eth0 \
  --ipv4 192.0.2.20/24 \
  --gateway 192.0.2.1 \
  --dns 192.0.2.53 \
  --ssh-key-file /root/.ssh/authorized_keys
```

在测试 VM 中，必须先创建可回滚快照，再执行 `--stage-test`，最后才允许做 destructive test。测试结束后停止 VM 并回滚快照，检查：

- raw image SHA256；
- GPT primary/backup header 和 partition start/size；
- EFI 文件和 NVRAM entry；
- Btrfs root 是否可以挂载和启动；
- Combustion 是否配置正确的 hostname、网络和 SSH key；
- 目标系统启动后是否能通过控制台和 SSH 访问。

## 已知限制

- 目标盘必须有独立控制台、救援介质或可回滚快照。
- `root=ro` 只影响新系统启动后的 root，不能替代 bootstrap；运行中的旧系统不能直接覆盖自己所在磁盘。
- `sync`、`blockdev --flushbufs`、`blockdev --setro` 和冻结旧 userspace 不能替代独立救援环境，必须继续验证旧 root 是否完全卸载。
- QEMU/zvol 可能保留旧 kernel partition mapping；不能只看当场的 `sfdisk` 输出，必须在重启/关机后从外部系统再次检查 on-disk GPT。
- 在将 flush/只读/GPT 流程用于真实物理机前，必须先在 disposable VM 中取得完整成功结果。

## 下一步开发计划（方案 2：kexec + 自制 initramfs）

当前 `pivot_root` 到 RAM tmpfs 的“RAM bootstrap”并不能真正剥夺旧系统对目标盘的访问：旧 systemd/PID1 仍然存活，旧 btrfs 的 async discard 和 writeback 会在 `dd` 之后继续写回目标盘。现已用轻量缓解压制（内层部署先 `mount -o remount,nodiscard /oldroot` 关闭 async discard，再强制 `fsfreeze`、`blockdev --setro`、`umount -Rl`），但这仍是权宜之计。

方案 2 用真正的内核切换替代 `pivot_root`：

1. 构建自制 initramfs（cpio + gzip/zstd），内置 `busybox`（提供 sh、dd、sfdisk、sgdisk、mkfs 等所需 applet）以及脚本需要的其他二进制和动态库。
2. 目标 raw image 内置进 initramfs，或在 initramfs 内通过 RAM 网络获取（配置临时静态 IP，HTTP 下载并校验 SHA256）；受 initramfs 大小限制时优先“RAM 内网络获取”。
3. 用 `kexec -l` 加载新内核与 initramfs，`kexec -e` 直接切换；旧内核、旧 systemd、旧 btrfs 被完整废弃，不再有旧 root 的 discard/writeback。
4. 新 initramfs 的 PID1 负责识别目标盘、按 `--root-size-gib` 重建 GPT、写入 image、创建 Combustion 分区并写入配置、创建 EFI 启动项，最后 `reboot -f`。
5. 复用现有的只读计划、`--execute`/`VPS2IMG_PIVOT_CONFIRM` 双重保护、参数校验和 Combustion 生成逻辑。

要点：kexec 需要内核支持，且加载的内核与 initramfs 必须匹配；initramfs 必须自带 GPT 和文件系统工具；网络下载需要 initramfs 内有网卡驱动和 DHCP 或静态网络配置。建议以参数开关（例如 `--boot-method kexec`）与现有 `pivot_root` 路径并存，先在 disposable VM 中验证后再考虑设为默认。

## 安全规则

- 不要移除 `--execute` 或 `VPS2IMG_PIVOT_CONFIRM` 双重保护。
- 不要把密码、私钥、authorized_keys 内容、真实内网地址或生产主机信息提交到仓库。
- 任何 destructive test 前先确认快照存在。
- 修改 GPT 后从独立系统检查，不要依赖当前内核的 partition mapping。
- 生产部署前必须使用独立 RAM、SystemRescue 或其他外部 OS；不要从目标系统自身运行在线覆盖。

## 开发检查

```bash
bash -n vps2img-pivot
```

本地环境信息读取：

```bash
test -f AGENTS.private.md && less AGENTS.private.md
```
