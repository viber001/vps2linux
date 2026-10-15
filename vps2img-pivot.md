# vps2img-pivot 原理与研发测试记录

`vps2img-pivot` 是**不使用 kexec** 的部署方式：它把部署工具和 raw image 放进一个 RAM-backed bootstrap，再用 `pivot_root` 离开旧系统，从 RAM 里把 image 写到目标整盘。本文记录它的原理、它与 kexec 方案（`vps2img-kexec`）的取舍，以及早期研发测试过程。

## 与 kexec 方案的区别

| | vps2img-pivot | vps2img-kexec |
|---|---|---|
| 脱离旧系统的方式 | `pivot_root` 到 RAM tmpfs | `kexec` 切内核 |
| 旧内核/旧 systemd | **仍然存活**（仅 `SIGSTOP` 冻结） | 被完整废弃 |
| 旧 root 写回风险 | 有，需轻量缓解压制 | 消除 |
| 前置依赖 | 无（不需要 kexec） | 需要 kexec（内核 ≥2.6.13，物理机/KVM/Xen/HN） |
| 适用 | kexec 不可用/被限制、但有独立整盘的机器 | kexec 可用的物理机或全虚拟 VPS |

两者都必须把 raw image 写入目标盘，这一点没有区别；区别只在“旧系统如何让出磁盘”。

## 原理

```text
源系统 (运行中)
┌──────────────────────────────────────┐
│ 探测 root/disk/NIC，下载校验 raw image │
│ 创建独立 RAM tmpfs (bootstrap)         │
│ 复制二进制/动态库/image/配置到 tmpfs   │
│ 脱离目标盘非 root 挂载点               │
│ pivot_root 到 tmpfs，卸载 dev/proc/sys │
└──────────────────────────────────────┘
                 │ 仍在旧内核上，但 PID1 已被冻结
                 ▼
RAM bootstrap 内层部署
┌──────────────────────────────────────┐
│ 脱离旧 SSH 会话（stdio 转控制台）      │
│ SIGSTOP 冻结旧 PID1/服务              │
│ kill 旧 sshd；dropbear 接管 22 端口    │
│ 禁用旧 root async discard (nodiscard) │
│ flush_disk；fsfreeze 冻结旧 root      │
│ blockdev --setro；umount -Rl /oldroot  │
│ dd 写入 raw image 到整盘               │
│ sgdisk 重建 GPT（p1/p2 保留 image）    │
│ root 扩到 --root-size-gib              │
│ Combustion 分区占满磁盘剩余空间        │
│ 写 /combustion/script；建 EFI 启动项   │
│ flush 后 reboot -f                     │
└──────────────────────────────────────┘
```

## 救援 SSH（dropbear 监听 22）

与 `vps2img-kexec` 一致，pivot 也能在部署期提供监听 22 的 dropbear 救援 shell，但两者的前提不同：

- kexec 在 `kexec -e` 后旧内核/旧 sshd 已消失，22 端口天然空闲。
- pivot 的旧系统仍然存活，**旧 sshd 一直占着 22**；`pivot_root` 只切挂载命名空间，不会终止它。

因此 pivot 的流程是：当源系统装有 `dropbear`（`dropbear` + `dropbearkey`）时，构建 bootstrap 会 stage 它们、现场生成临时 host key，并把 `--ssh-key-file` 拷进 `root/.ssh/authorized_keys`。进入 RAM bootstrap 后：

1. `detach_and_takeover_console`：把 bootstrap 与外层 shell 的 stdio 切到 `/dev/console`、`/dev/ttyS0`、`/dev/tty0` 并 `trap '' HUP`，**先脱离旧 SSH 会话的 pty**——否则后面 kill 旧 sshd 会连带 SIGHUP 掉部署器自身。
2. `SIGSTOP` 冻结旧 PID1 后，`kill -TERM` 旧 sshd，再 `start_dropbear` 起来接 22（`-s` 仅公钥登录，`-r` 用临时 host key；旧 sshd 的监听 socket 可能短暂残留，故带重试）。
3. `trap ... EXIT` 进入 `rescue()`：重启 dropbear 并在控制台开 shell，写盘失败也不退出。

未安装 `dropbear` 时整段跳过，旧 sshd 与操作员会话原样保留（此时控制通道仍是旧系统的 SSH）。这与 kexec 的“仅 root 公钥、host key 构建期临时生成”保持一致的语义。

目标首启由镜像自带引导程序启动，dracut 的 `35combustion` 按 label `combustion` 找到配置分区并执行 `/combustion/script`。这与 `vps2img-kexec` 完全一致（见 `vps2img-kexec.md`）。

## 为什么仍然不安全（方案 2 的由来）

`pivot_root` 只切换了挂载命名空间的根，**并不会终止旧 init 系统**：旧 kernel、旧 PID1、旧 Btrfs 都仍在运行（脚本通过 `kill -STOP 1` 和一组 `SIGSTOP` 冻结，但这只是暂停，不是撤销）。旧 root 的 **async discard** 与**脏页回写**可能在内层 `dd` 写完之后才落盘，从而破坏刚写入的镜像。这层不确定性就是 AGENTS.md 提出“方案 2：kexec + 自制 initramfs”的根本原因——kexec 真正废弃旧内核，从根上消除该风险。

因此 vps2img-pivot 是**可用但安全余量较低**的方案，面向 kexec 不可用的环境。

## 研发测试过程

全部提交（`git log --oneline -- vps2img-pivot`）：

### 1. `006165b` Add vps2img-pivot raw image deployer

初版：从运行中的系统把 raw image 部署到整盘，采用 RAM bootstrap + `pivot_root`。安全门控：默认只 dry-run，只有 `--execute` + `VPS2IMG_PIVOT_CONFIRM=WIPE:<disk>` 同时存在才擦盘。

### 2. `6955304` / `fe50a93` 记录测试环境与 iVentoy 背景

明确目标镜像来自 iVentoy EISO HTTP 内容（`http://…/eiso/id/3/`），因为 iVentoy 的 PXE 不直接支持 `SelfInstall` ISO。

### 3. `1629535` Fix for the KIWI first-boot repartition（关键）

**现象**：部署成功、GPT 正确，但目标首启失败，GRUB 报 `no such device: 9fe4216a-…`（root 的 btrfs UUID）。串口显示 shim 加载后立即找不到设备。

**根因**：Leap Micro 的 KIWI 首启运行 dracut 模块 `55kiwi-repart/kiwi-repart-disk.sh`：只要磁盘上还有超过约 10 MiB 的**未分配空间**，它就执行 `d 3 ; n p:lxroot 3 . .`——删掉 `kiwi_RootPart`(=3) 并在最后一个分区之后重建。于是 root 被搬到最后、原来的 Btrfs 失去分区覆盖，GRUB 按 UUID `search` 失败。（`--oemrootMB`、`rd.kiwi.oem.*` 等开关都不控制这一步。）

**修复**：让 Combustion 配置分区（sda4）占满 root 之后的**全部**空间，不留未分配空间；`kiwi-repart` 因空闲不足（`min_additional_mbytes=10`）跳过，root 保持原位。

**同批修复**：

- **watchdog**：PVE guest 有 `softdog`（10s 超时），由 `watchdog-mux` 喂狗。RAM bootstrap 的 `SIGSTOP` 冻结列表里原本含 `watchdog-mux`，一旦冻结唯一喂狗者，软狗在 `dd` 后约 10s 硬复位，部署中断。修复：把 `watchdog-mux` 移出冻结列表。
- **sfdisk 解析**：`sfdisk --dump` 输出 `start=        2048,`（`=` 后有空格，值右对齐），旧匹配 `$i ~ "^"key"="` 会命中空值，导致 Combustion 偏移计算失败。改用 `match($0, key "= *[^, ]+")` 提取。

### 4. `b71e202` Harden the old-root disarm and enable the VGA console

- 旧 root 卸载流程强化：尝试 `mount -o remount,ro /oldroot`，失败则 bind 只读，再 `blockdev --setro`，最后 `umount -Rl`。
- VGA 控制台：VM 用 `vga: serial0` 时 PVE 传 `-nographic`，没有帧缓冲、Web 控制台一片空白。修复：`qm set --vga std`，并让 Combustion 往内核命令行注入 `console=tty0`（改 grub.cfg、`/etc/default/grub`、`/etc/sysconfig/bootloader`），下次启动后串口与 VGA 双显。

> 这一步后来被证明方向不对：失败的空闲 root `remount,ro` 并不能阻止回写（见下一步），于是在 `b20780e` 里被替换。

### 5. `b20780e` Disable async discard and freeze the former root（最终缓解）

**现象**：部分 run 部署后目标起不来，串口 `dracut:/root#` 应急 shell，`BTRFS error (device sda3): csum failed root 258 ino 21803 … corrupt 6..10`——**数据块损坏**（`btrfs check` 不报，因为它不校验数据）。`ino 21803` 对应镜像里的 `usr/lib64/ld-linux-x86-64.so.2`。

**根因**：旧 root 仍挂着 `discard=async`，其后台 discard workqueue 会对**刚写入镜像的空闲块**发起 TRIM；在 zvol/SSD 上 TRIM 会把盘上刚写的数据清零，于是新镜像损坏。此外旧的失败 root `remount,ro` 会残留待回写脏页，在 `dd` 之后落盘。

**修复**（当前形式）：

```text
mount -o remount,nodiscard /oldroot      # 只读 remount 会 EBUSY，但纯 discard 关停会被接受
flush_disk                                # sync + blockdev --flushbufs
fsfreeze --freeze /oldroot                # 必须成功，否则拒绝覆盖（写入前会把上面缓冲刷下去）
blockdev --setro "$VPS2IMG_PIVOT_ROOT_SOURCE" # 失败仅告警
umount -Rl /oldroot                       # 懒卸载
```

实测要点：`mount -o remount,ro /` 在忙 root 上 **EBUSY**；但 `mount -o remount,nodiscard /` 会成功并从 `findmnt` 里去掉 `discard=async`。往 `/sys/fs/btrfs/*/discard/{iops_limit,kbps_limit}` 写 0 **不能**真正停掉 discard（`discardable_bytes` 仍在涨），所以只用 remount 方式。

### 6. 验证结果

- VM 600（PVE ext4+LVM 源）：RAM bootstrap 覆盖为 Leap Micro `EFI+Btrfs`，`efibootmgr` 建 `vps2img-pivot` 启动项，Combustion 首启生效静态 IP 与 SSH 公钥。
- VM 602（PVE Btrfs 源，400 GiB）：端到端成功，root 100 GiB、Combustion 填满剩余空间；首启后 hostname、静态 IPv4、SSH 公钥均由 Combustion 生效。
- 加入 `nodiscard`+`fsfreeze` 缓解后，多轮部署得到干净结果（无 `csum failed`，`ld-linux` 完整）。
- **间歇性故障**：曾出现一次 `pivot_root` 之后面板侧突然复位（无内核 panic、非 watchdog、非脚本错误路径），第二次 `qm reset` 可恢复；其余轮次均干净。原因未最终定位。

## 已知限制

- 旧内核/旧 systemd 未真正终止，存在理论上的旧 root 写回/损坏风险；缓解只降低概率，不根除。要根除请用 `vps2img-kexec`（kexec）。
- `root=ro` 只影响新系统启动后的 root，不能替代 bootstrap。
- QEMU/zvol 可能保留旧分区映射；改 GPT 后必须从重启/外部系统复核 on-disk GPT。
- 破坏性工具：目标盘必须有独立控制台、救援介质或可回滚快照；默认只探测与 dry-run。
