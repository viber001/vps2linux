# vps2img-kexec 原理

`vps2img-kexec` 用运行中的 Linux 作为引导器，把另一套 Linux raw image 部署到目标整盘。它和 `vps2img-pivot` 的最大区别是**用 `kexec` 切换内核**而不是 `pivot_root` 到 RAM tmpfs：旧内核、旧 systemd、旧 root 文件系统在 `kexec -e` 之后被完整废弃，因此旧 root 的 async discard / writeback 不可能再覆盖刚写入目标盘的数据。

## 与 vps2img-pivot 的定位差异

- `vps2img-pivot`：`pivot_root` 到 tmpfs 的“RAM bootstrap”，旧 PID1 仍存活，需要轻量缓解（`mount -o remount,nodiscard` + `fsfreeze` + `blockdev --setro`）压制旧 root 的写回。
- `vps2img-kexec`：真正的内核切换，从根上消除旧系统对目标盘的访问。代价是必须能 `kexec`（见下文 Secure Boot 限制）。

## 整体流程

```text
源系统 (运行中)                RAM initramfs (PID1)              目标首启
┌───────────────────┐         ┌────────────────────────┐        ┌──────────────────┐
│ 探测 root/disk/NIC │         │ 流式写 raw image→disk  │        │ 镜像自引导        │
│ 下载/校验 raw image│  kexec  │ sgdisk 重建 GPT        │  reboot│ Combustion 生效   │
│ 构建自制 initramfs │ ──────► │ mkfs.ext4 combustion   │ ─────► │ hostname/网络/用户│
│ kexec -l / kexec -e│         │ 写 /combustion/script  │        │ SSH key / sudo    │
└───────────────────┘         │ 扩容 root、建 EFI 项   │        └──────────────────┘
                              │ reboot -f              │
                              └────────────────────────┘
```

### 阶段 A：源系统

1. 识别当前 root、底层 whole disk、网络接口（bridge 映射到物理 member）。
2. 下载 raw image（或从 HTTP 流式，见阶段 B）并校验 SHA256。
3. 生成只读计划；只有 `--execute` 与 `VPS2IMG_KEXEC_CONFIRM=WIPE:<disk>` 同时存在才继续。
4. 构建自制 initramfs（cpio + gzip），用 `kexec -s -l`（`kexec_file_load`）加载源内核 + 该 initramfs，`kexec -e` 切换。

### 阶段 B：RAM initramfs 的 PID1

自制 initramfs 里没有 systemd，PID1 是 `/init` 脚本，依次：

1. `load_required_modules`：写入 mdev 的 modalias 自动加载规则、`mdev -s`，再 `modprobe` 必要模块。
2. 通过 HTTP **流式**下载 raw image 并直接写入目标盘（`wget -O - | dd bs=4M`），全程不把镜像放进内存；写入后回读头部校验 SHA256。
3. `sgdisk` 重建 GPT（保留 raw image 的 BIOS/EFI 分区 GUID）。
4. 用 loop 设备 `mkfs.ext4 -L combustion` 建配置分区，写入 `/combustion/script`。
5. 把 root 分区 `btrfs filesystem resize max` 扩到 `--root-size-gib`。
6. `efibootmgr` 创建 EFI 启动项，`flush_disk` 后 `reboot -f`。

### 阶段 C：目标首启

重启后由 sda 上镜像自己的引导程序（shim → grub → 镜像内核）启动；dracut 的 `35combustion` 模块按分区 label `combustion` 找到配置分区，挂载并执行 `/combustion/script`，完成 hostname、静态网络、用户名/密码、SSH key 与 sudo 配置。

## initramfs 内容

- `busybox`（`sh`、`dd`、`mdev`、`wget` 等 applet）。
- 必要动态库，以及脚本需要的二进制：`sfdisk`、`sgdisk`、`mkfs.ext4`、`efibootmgr`、`btrfs`、`kexec` 等。
- **硬件驱动**：按“用到 `ko` 的设备”收集，而不是全量塞入，以便在物理机上启动：
  - `lsmod` 里所有在用模块；
  - 目标磁盘、网卡的**整条设备链**对应模块（走 `driver` 的 `module` 符号链接，跳过 builtin）；
  - 对 bridge/bond 网卡跟随到有 `/device` 的 member；
  - 每个模块带上 `modprobe --show-depends` 的依赖闭包。
- 可选 `dropbear`（initramfs 内提供 SSH 以便调试）。

## 目标磁盘布局

```text
sda1  保留 raw image 的 BIOS 分区和 GUID
sda2  保留 raw image 的 EFI 分区和 GUID
sda3  Btrfs root，`--root-size-gib`（写盘后 mount 并 resize max）
sda4  ext4，label=combustion，扩展到磁盘末尾，不留未分配空间
```

`sda4` 必须占满 root 之后的全部空间：Leap Micro 的 KIWI 首启会搜索大于约 10 MiB 的空闲空间并把 root 分区搬到最后（`kiwi-repart` 的 `d 3 ; n p:lxroot 3 . .`），留空闲会让 root 被搬走、Btrfs 失联、GRUB 报 `no such device`。填满后 `kiwi-repart` 因空闲不足而跳过，root 保持在原位。

## 配置：Combustion，不是 cloud-init

raw image **没有安装 cloud-init**（也没有对应 dracut 模块），只带 openSUSE 原生的 Combustion / Ignition。因此 `vps2img-kexec` 使用 Combustion 契约：

- 分区 label 必须是 `combustion`，脚本位于 `/combustion/script`；
- 写入内容：hostname、`NetworkManager` 连接（按 MAC 匹配网卡、静态 IPv4/gateway/DNS）、`root` 的 `authorized_keys`、创建 `--user`/`--password`、给该用户加 `wheel` 组并写 `/etc/sudoers.d/wheel`。
- Leap Micro 自带 `Defaults targetpw`，单写 `%wheel ALL=(ALL:ALL) ALL` 仍会要求 **root 密码**；需一并写 `Defaults:%wheel !targetpw` 才会用调用者自己的密码。

## Secure Boot

官方 `openSUSE-Leap-Micro-...-SelfInstall` ISO 是**全程 Secure Boot 兼容**的，稳定保持 Secure Boot 开启：

```text
固件 → shim (EFI/BOOT/bootx64.efi, SUSE/Microsoft 签名)
     → grub (EFI/BOOT/grub.efi, openSUSE 签名)
     → 内核+initrd (boot/x86_64/loader/{linux,initrd}, openSUSE 签名)
     → dracut kiwi-dump 写入 OEM raw image → kiwi-dump-reboot 重启
     → 目标镜像自带 shim 继续以 Secure Boot 启动
```

ISO 内的证据（`http://10.68.247.14:16000/eiso/id/3/`）：

- `EFI/BOOT/bootx64.efi` 内含 `UEFI SHIM` / `shim.c` 等字符串 —— 是 shim；
- `EFI/BOOT/{grub.efi,MokManager.efi}` —— 签名 grub 与 MOK 管理程序；
- `boot/x86_64/loader/linux` = 内核 `6.12.0-160000.35-default`，含 `$SUSE Linux Enterprise Secure Boot CA1`；
- `boot/x86_64/loader/initrd` 提供 dracut 模块 `55kiwi-dump` / `59kiwi-dump-reboot`（官方“写盘后重启”的实现）；
- `boot/grub2/{grub.cfg,earlyboot.cfg}` 以 `root=install:CDLABEL=INSTALL` 引导安装内核。

**关键点**：官方自安装**不使用 `kexec`**，它由固件直接引导已签名的安装内核，安装内核自己写盘后重启。整条链都已签名，所以 Secure Boot 无需关闭。

`vps2img-kexec` 在 Secure Boot 开启时通过 `kexec_file_load` 工作，**无需关闭 Secure Boot**：

- 启用 Secure Boot 时内核进入 lockdown，只允许 `kexec_file_load`（`kexec -s`），禁止旧 syscall `kexec_load`（`kexec -c`，会报 `kexec_load failed: Operation not permitted on UEFI SecureBoot`）。
- `kexec_file_load` 要求被加载的内核镜像已被固件信任或签名。脚本默认加载**当前正在运行的内核**（`/boot/vmlinuz-$(uname -r)`，可用 `--kernel` 覆盖），它已经在 Secure Boot 下启动，因此是受信任的；自制 initramfs 作为数据附加，不参与内核签名校验。
- 因此 `run_kexec` 与 `--stage-test` 默认先尝试 `kexec -s -l`；只有 `-s` 失败且系统未处于 lockdown 时才回退到 `kexec -c -l`（打印明确提示）。lockdown 检测不再致命，只告警并走 `-s` 路径。

> 注意：`kexec_file_load` 加载的内核必须是当前运行的内核（或镜像自带的已签名内核）。换用未签名的自定义内核在 Secure Boot 下仍会被拒绝。

## 已验证范围

- VM 600（PVE ext4+LVM 源）、VM 602（PVE Btrfs 源）：`kexec -e` → 流式写盘 → Combustion → 重启 → Leap Micro 启动，hostname/网络/用户/密码/SSH key/sudo 全部生效，Btrfs 无损坏，Combustion 分区首启后仍在。
- VM 600 在 **Secure Boot 开启**（`mokutil --sb-state` = `SecureBoot enabled`，lockdown integrity）下：`--stage-test` 用 `kexec_file_load`（`-s`）加载 23.7 MiB initramfs 成功，完整 `--execute` 部署进入 Leap Micro 6.2，目标端 Secure Boot 仍为 enabled。
- 物理机 c49（Inspur NS5488M5 节点，Debian 13 + PVE 源）：驱动按整条设备链收集，`eno2` 物理网卡上电，部署成功进入 Leap Micro。
- 在 openSUSE Leap Micro 6.2 源（无可用的 `apt`、无 `ar`/binutils）上验证：`debian`（该源上 `auto` 也解析为它）经 HTTP 组装 ramdisk 后 `--execute` 部署成功，目标 `pve2-leap-test` 启动、静态网络/用户/密码/wheel sudo/SSH key 生效，Btrfs 无损坏；`--ramdisk-source apt` 在该源上按预期拒绝（无 `apt-get`）。`apt` 模式在 PVE Debian 源上（缺 `kexec-tools`）经 `apt-get` 补齐后按 host 模式构建成功。
- Harvester 节点（Harvester v1.8.2 / SLES 16，root 是 loop 设备 `/dev/loop0`，backing file `/cOS/active.img` 落在 `COS_STATE` 分区）：`discover_source` 新增 loop-root 回退后，p123 / p126 的 `--dry-run` 均输出完整计划（`source root: /dev/loop0 (ext2)`、`source disk: /dev/sda`），stream 与 embed 两种镜像模式皆可用。PVE ext4+LVM、PVE/Leap Micro Btrfs 等非 loop 根不受影响。

## 已知限制

- 需要关闭 Secure Boot 仅当你用 `--kernel` 指定了一个非当前运行的、未签名/未受信任的内核；默认加载当前运行内核时 Secure Boot 可保持开启（见上）。
- 源系统默认（`--ramdisk-source auto`）在宿主工具齐全时直接 staging 宿主（`host`），缺工具则改为经 HTTP 获取 d-i 组件（`debian`）；`--ramdisk-source host` 强制宿主并缺则报错，`debian` 强制下载（无需宿主包管理器，适用于 Leap Micro 等非 apt 源），`apt` 先用 `apt-get` 补齐缺失工具再 staging 宿主。读 `.deb/.udeb` 需要 `ar`，缺失时回退到宿主 busybox 的 `ar` applet，仍缺失则下载 busybox.net 的静态 busybox。
- 驱动收集只在 virtio 与 Inspur 的网卡/磁盘路径上验证过，其他 AHCI/NVMe/RAID 控制器尚待在物理机验证。
- 源根为 loop 设备（不可变 OS 镜像，如 Harvester/cOS）时，脚本用 `/sys/block/<loop>/loop/backing_file` 配合当前挂载点反查该文件所在的整盘；要求 backing file 所在分区仍处于挂载状态（Harvester 的 `COS_STATE` 挂在 `/run/initramfs/cos-state`）。
- 这是破坏性实验工具，默认只探测与 dry-run；目标盘必须有独立控制台、救援介质或可回滚快照。
