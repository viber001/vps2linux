# Combustion 首启脚本（完整生成结果与行为分析）

本文件记录 `vps2img-pivot` / `vps2img-kexec` 写到 Combustion 分区（`sda4`，`LABEL=combustion`）的 `/combustion/script`，用于分析目标系统**首启时**的行为，尤其是扩容与 10 MiB 空洞的配合。

- 源片段：`src/assets/combustion.sh`（3 行 INCLUDE）→ `combustion-base.sh` + `combustion-user.sh` + `combustion-growroot.sh`。
- 注入方式：两个部署器都在内层 deployer 里用 `(#@HEREDOC@expand) cat > /config/combustion/script <<COMBUSTION | src/assets/combustion.sh`，因此 `@PROGRAM@`、`$TARGET_*`、`$AUTHORIZED_KEYS` 在**部署时**替换为字面量；`\$ROOT` 等转义保留为脚本运行时展开。为避免 authorized key 内容提前结束嵌套 heredoc，部署前会拒绝整行 `SSHKEYS`、`USERKEYS` 及当前使用的 marker；key 文件是文本，只有 OpenSSH key body 是 base64。
- 两个部署器生成的脚本**除程序名外完全一致**（`diff` 仅 6 处 `vps2img-pivot` ↔ `vps2img-kexec`）。密码只应作为临时 bootstrap credential：脚本使用 `set -x`，密码可能出现在 Combustion journal/log 中；目标系统重启并确认 SSH 可用后必须立即修改密码。
- 下面正文保留 `@PLACEHOLDER@` 形式，代表部署时会被替换的部分。

## 生成结果（完整）

```bash
#!/bin/bash
set -euxo pipefail

if [[ -d /sysroot/etc ]]; then
	ROOT=/sysroot
else
	ROOT=/
fi
echo '$TARGET_HOSTNAME' > "$ROOT/etc/hostname"

mkdir -p "$ROOT/etc/NetworkManager/system-connections"
cat > "$ROOT/etc/NetworkManager/system-connections/@PROGRAM@.nmconnection" <<'NETWORK'
[connection]
id=@PROGRAM@
type=ethernet
autoconnect=true

[802-3-ethernet]
mac-address=$TARGET_MAC

[ipv4]
method=manual
address1=$TARGET_IPV4_CIDR,$TARGET_GATEWAY
dns=$TARGET_DNS

[ipv6]
method=disabled
NETWORK

	# Prefer the saved bridge member MAC. If the target kernel exposes a
	# different predictable name, NetworkManager can still match the device by
	# MAC. If that fails, use the saved member/altnames, then the first UP NIC.
	TARGET_INTERFACE_NAMES='$TARGET_INTERFACE_NAMES'
	TARGET_MAC='$TARGET_MAC'
	find_by_mac() {
		local path name address
		for path in /sys/class/net/*; do
			[[ -r "$path/address" ]] || continue
			name=${path##*/}
			[[ "$name" == lo ]] && continue
			address=$(tr '[:upper:]' '[:lower:]' < "$path/address")
			if [[ "$address" == "$TARGET_MAC" ]]; then
				printf '%s\n' "$name"
				return 0
			fi
		done
		return 1
	}
	find_by_name() {
		local candidate old_ifs=$IFS
		IFS=,
		for candidate in $TARGET_INTERFACE_NAMES; do
			if [[ -d "/sys/class/net/$candidate" && "$candidate" != lo ]]; then
				printf '%s\n' "$candidate"
				IFS=$old_ifs
				return 0
			fi
		done
		IFS=$old_ifs
		return 1
	}
	find_first_up() {
		local path name state
		for path in /sys/class/net/*; do
			[[ -r "$path/operstate" ]] || continue
			name=${path##*/}
			[[ "$name" == lo ]] && continue
			state=$(cat "$path/operstate" 2>/dev/null || true)
			if [[ "$state" == up ]]; then
				printf '%s\n' "$name"
				return 0
			fi
		done
		return 1
	}
	SELECTED_INTERFACE=$(find_by_mac || true)
	NETWORK_MATCH=mac
	if [[ -z "$SELECTED_INTERFACE" ]]; then
		SELECTED_INTERFACE=$(find_by_name || true)
		NETWORK_MATCH=name
	fi
	if [[ -z "$SELECTED_INTERFACE" ]]; then
		SELECTED_INTERFACE=$(find_first_up || true)
		NETWORK_MATCH=name
	fi
	{
		printf '%s\n' '[connection]' 'id=@PROGRAM@' 'type=ethernet' 'autoconnect=true'
		if [[ "$NETWORK_MATCH" == mac ]]; then
			printf 'mac-address=%s\n' "$TARGET_MAC"
		elif [[ -n "$SELECTED_INTERFACE" ]]; then
			printf 'interface-name=%s\n' "$SELECTED_INTERFACE"
		fi
		printf '%s\n' '' '[ipv4]'
		printf 'method=manual\naddress1=%s,%s\ndns=%s\n' '$TARGET_IPV4_CIDR' '$TARGET_GATEWAY' '$TARGET_DNS'
		printf '%s\n' '' '[ipv6]' 'method=disabled'
	} > "$ROOT/etc/NetworkManager/system-connections/@PROGRAM@.nmconnection"
	chmod 600 "$ROOT/etc/NetworkManager/system-connections/@PROGRAM@.nmconnection"

mkdir -p "$ROOT/root/.ssh"
cat > "$ROOT/root/.ssh/authorized_keys" <<'__VPS2IMG_ROOT_AUTHORIZED_KEYS__'
$AUTHORIZED_KEYS
__VPS2IMG_ROOT_AUTHORIZED_KEYS__
chmod 700 "$ROOT/root/.ssh"
chmod 600 "$ROOT/root/.ssh/authorized_keys"

# Mirror kernel and systemd output to the VGA console in addition to the serial
# console, so the boot is visible on the PVE web console even when the serial
# console is not attached. The image already carries console=tty0 in
# GRUB_CMDLINE_LINUX_DEFAULT, but its generated grub.cfg omitted it; patch the
# effective grub.cfg directly and update the bootloader defaults so later
# grub2-mkconfig runs keep the setting. Effective from the next boot.
if [[ -f "$ROOT/boot/grub2/grub.cfg" ]] && ! grep -q 'console=tty0' "$ROOT/boot/grub2/grub.cfg"; then
	sed -i 's/console=ttyS0,115200/console=ttyS0,115200 console=tty0/g' "$ROOT/boot/grub2/grub.cfg"
fi
if [[ -f "$ROOT/etc/default/grub" ]] && ! grep -q 'console=tty0' "$ROOT/etc/default/grub"; then
	sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 console=tty0"/' "$ROOT/etc/default/grub"
fi
if [[ -f "$ROOT/etc/sysconfig/bootloader" ]] && ! grep -q 'console=tty0' "$ROOT/etc/sysconfig/bootloader"; then
	sed -i 's/^\(DEFAULT_APPEND="[^"]*\)"/\1 console=tty0"/; s/^\(FAILSAFE_APPEND="[^"]*\)"/\1 console=tty0"/' "$ROOT/etc/sysconfig/bootloader"
fi

# Provision the requested login user, its password and its SSH key. Leap
# Micro's Combustion chroots into the target root before running this script
# (so ROOT is usually /); when a /sysroot layout is used instead, run the
# account tools through chroot so they still act on the target.
TARGET_USER='$TARGET_USER'
TARGET_PASSWORD='$TARGET_PASSWORD'
run_in_target() {
	if [[ "$ROOT" == / ]]; then
		"$@"
	else
		chroot "$ROOT" "$@"
	fi
}
ensure_user() {
	local user=$TARGET_USER home uid_gid
	if [[ "$user" != root ]] && ! grep -q "^$user:" "$ROOT/etc/passwd"; then
		run_in_target /usr/sbin/useradd -m -s /bin/bash "$user" || \
			run_in_target /usr/sbin/useradd -m "$user"
	fi
	if [[ -n "$TARGET_PASSWORD" ]]; then
		printf '%s:%s\n' "$user" "$TARGET_PASSWORD" | run_in_target /usr/sbin/chpasswd
	fi
	home=$(awk -F: -v u="$user" '$1==u{print $6}' "$ROOT/etc/passwd")
	[[ -n "$home" ]] || home=/root
	uid_gid=$(awk -F: -v u="$user" '$1==u{print $3":"$4}' "$ROOT/etc/passwd")
	mkdir -p "$ROOT$home/.ssh"
	cat > "$ROOT$home/.ssh/authorized_keys" <<'__VPS2IMG_USER_AUTHORIZED_KEYS__'
$AUTHORIZED_KEYS
__VPS2IMG_USER_AUTHORIZED_KEYS__
	chmod 700 "$ROOT$home/.ssh"
	chmod 600 "$ROOT$home/.ssh/authorized_keys"
	if [[ -n "$uid_gid" ]]; then
		chown -R "$uid_gid" "$ROOT$home/.ssh"
	fi
	# /home is a separate btrfs subvolume on Leap Micro and is NOT part of a
	# transactional-update snapshot, so a key written under the user home here
	# is shadowed on the first real boot. /etc IS captured by the snapshot, so
	# also install the key under /etc/ssh/authorized_keys.d and let sshd read it
	# (AuthorizedKeysFile drop-in below); a firstboot unit recreates the real
	# ~/.ssh on the /home subvolume.
	mkdir -p "$ROOT/etc/ssh/authorized_keys.d"
	cat > "$ROOT/etc/ssh/authorized_keys.d/$user" <<'__VPS2IMG_USER_AUTHORIZED_KEYS__'
$AUTHORIZED_KEYS
__VPS2IMG_USER_AUTHORIZED_KEYS__
	chmod 644 "$ROOT/etc/ssh/authorized_keys.d/$user"
	chown root:root "$ROOT/etc/ssh/authorized_keys.d/$user"
	chmod 755 "$ROOT/etc/ssh/authorized_keys.d"
}
ensure_user

# The user home lives on the /home subvolume, which Combustion cannot write
# (see above). Materialize ~/.ssh there on the first real boot from the copy
# under /etc, so the requested user ends up with a working authorized_keys.
if [[ '$TARGET_USER' != root ]]; then
	mkdir -p "$ROOT/etc/systemd/system"
	cat > "$ROOT/etc/systemd/system/@PROGRAM@-user-home.service" <<UNIT
[Unit]
Description=Create home and SSH authorized_keys for $TARGET_USER
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/install -d -m 0700 -o $TARGET_USER -g $TARGET_USER /home/$TARGET_USER/.ssh
ExecStart=/usr/bin/install -m 0600 -o $TARGET_USER -g $TARGET_USER /etc/ssh/authorized_keys.d/$TARGET_USER /home/$TARGET_USER/.ssh/authorized_keys
ExecStart=/usr/bin/chown -R $TARGET_USER:$TARGET_USER /home/$TARGET_USER

[Install]
WantedBy=multi-user.target
UNIT
	systemctl --root="$ROOT" enable @PROGRAM@-user-home.service
fi

mkdir -p "$ROOT/etc/ssh/sshd_config.d"
cat > "$ROOT/etc/ssh/sshd_config.d/90-@PROGRAM@.conf" <<SSHD
PermitRootLogin $SSHD_ROOT_LOGIN
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u
PasswordAuthentication $SSHD_PASSWORD_AUTH
SSHD

# Add the created user to wheel and let the group run sudo with the caller's
# own password. openSUSE ships `Defaults targetpw`, so a plain `%wheel` rule
# would still ask for ROOT's password; override it for the group.
if [[ '$TARGET_USER' != root ]]; then
	run_in_target usermod -aG wheel '$TARGET_USER' 2>/dev/null || \
		run_in_target gpasswd -a '$TARGET_USER' wheel 2>/dev/null || true
	if [[ -e "$ROOT/usr/etc/sudoers" || -e "$ROOT/etc/sudoers" ]]; then
		mkdir -p "$ROOT/etc/sudoers.d"
		cat > "$ROOT/etc/sudoers.d/wheel" <<'SUDOERS'
Defaults:%wheel !targetpw
%wheel ALL=(ALL:ALL) ALL
SUDOERS
		chmod 0440 "$ROOT/etc/sudoers.d/wheel"
		chown root:root "$ROOT/etc/sudoers.d/wheel"
	fi
fi

systemctl --root="$ROOT" enable sshd.service
systemctl --root="$ROOT" enable NetworkManager.service
# Grow the root filesystem to fill its partition. kexec does this in its
# initramfs before the first boot; pivot cannot (the old kernel still holds the
# former root's frozen btrfs superblock), so for pivot this is the only resize.
# It is idempotent (a no-op once the filesystem fills the partition).
if command -v btrfs >/dev/null 2>&1; then
	btrfs filesystem resize max "$ROOT" 2>/dev/null || true
fi
```

## 执行时序（首启）

1. initrd 挂载镜像 root 到 `/sysroot`（Leap Micro 的 `root=` 由镜像自带 cmdline 决定）。
2. systemd 在 `sysroot.mount` 之后、`multi-user.target` 之前运行 `combustion.service`，执行 `/combustion/script`。
3. 脚本以 `set -euxo pipefail` 运行；**`-x` 会把每条命令写进 journal**（`journalctl -b -u combustion`），包括可能包含密码的命令。因此 `--password` 只能使用临时密码，目标重启并确认 SSH 可用后应立即修改，不要复用正式密码。
4. `/combustion` 即 `sda4`（`LABEL=combustion`）。成功的首启会消费该分区：实测第二次启动时 `/combustion` 已不存在。
5. 脚本里的写入走 `transactional-update` 语义，journal 可见 `Warning: The following files were changed in the snapshot, but are shadowed by other mounts`（`/.snapshots/2/snapshot/home/leap/...`），属预期提示。

## 关键行为点

### 扩容（`combustion-growroot.sh`）

```bash
if command -v btrfs >/dev/null 2>&1; then
	btrfs filesystem resize max "$ROOT" 2>/dev/null || true
fi
```

- `ROOT` 在 initrd 阶段是 `/sysroot`，正常启动后是 `/`；两者都指向同一个 btrfs 顶层（`subvolid=5`），`resize max` 作用于设备，而不是某个子卷。
- 幂等：已占满分区时是 no-op；失败被 `|| true` 吞掉，不阻断首启。
- **为什么必须保留**：部署器让 `sda4` 铺满 root 之后的全部空间（不留空洞），Leap Micro 的 `kiwi-repart`/growroot 因此认为磁盘已满、不再自动扩容；若不在这里扩，root 会停在小镜像尺寸（实测 2.80 GiB）。
- pivot 部署器**不再**在 RAM 里扩容（旧内核持有冻结的旧 btrfs superblock，`resize` 会永久 D 状态），所以这段是 pivot 的**唯一**扩容路径；kexec 先在 initramfs 里扩一次，这里作为幂等兜底。
- 实测证据：

```text
+ btrfs filesystem resize max /
BTRFS info (device sda3): resize device /dev/sda3 (devid 1) from 3010441216 to 107374182400
```

  `df -h /` → `100G`，`findmnt -no SIZE /` → `100G`。

### 与 10 MiB 空洞的关系

- 部署器的 `deploy-gpt.sh` 断言 `sda4` 之后的剩余空间 `< 10 MiB`，否则 `fail "target disk still has N free sectors; Leap Micro would repartition it"`。
- 原因：`kiwi-repart` 只要发现**最后一个分区之后还有可用空间**，就会重排分区并把 root 搬过去（在最后一个分区之后重建 `kiwi_RootPart`），搬动后 root 文件系统与启动参数失联。10 MiB 是给 GPT backup header（33 扇区）留的余量，计算用 `LAST_USABLE = DISK_SECTORS - 34`。
- 两者配合：`sda4` 填满到 `LAST_USABLE` → 首启 `kiwi-repart` 放弃重排 → 由本脚本 `btrfs resize max` 把 root 扩到 `sda3` 的 100 GiB，而不是扩到整盘。

### 网络

- 先按**保存的 MAC** 匹配（`find_by_mac`），失败再按 `TARGET_INTERFACE_NAMES`（源系统主接口名 + altname 列表）匹配，最后退化为第一个 `operstate == up` 的网卡。
- 匹配方式决定 nmconnection 用 `mac-address=` 还是 `interface-name=`；最终会重写一次文件（前面带 `mac-address` 的初稿被覆盖）。
- 若三种都失败，`SELECTED_INTERFACE` 为空且不写 `interface-name`；届时只能依赖 `autoconnect=true` 与唯一有线网卡，不再有保证。

### 用户与 SSH

- `combustion-user.sh` 创建目标用户（`-m -s /bin/bash`）、加入 `wheel`、设置密码、写 `/home/<user>/.ssh/authorized_keys`，并用 `@PROGRAM@-user-home.service` 在首登时补家目录。
- `90-@PROGRAM@.conf`：`PermitRootLogin prohibit-password`、`PasswordAuthentication yes`。
- root 的 `authorized_keys` 由 `combustion-base.sh` 直接写入，内容即 `--ssh-key-file`。
- openSUSE 默认 `Defaults targetpw`，脚本另写 `sudoers.d/wheel`，让 wheel 用户用**自己的**密码 sudo。

## 两版差异

`diff` 两个构建产物抽出的脚本，只有程序名字面量不同：

| 位置 | pivot | kexec |
|---|---|---|
| nmconnection 文件名 | `vps2img-pivot.nmconnection` | `vps2img-kexec.nmconnection` |
| connection id | `vps2img-pivot` | `vps2img-kexec` |
| 用户 home 单元 | `vps2img-pivot-user-home.service` | `vps2img-kexec-user-home.service` |
| sshd drop-in | `90-vps2img-pivot.conf` | `90-vps2img-kexec.conf` |

首启脚本**不负责**重启：重启发生在部署器的内层 deployer（写入、重建 GPT、写 Combustion 之后），见 `src/assets/deploy-reboot.sh` 与 `--reboot-delay`。

均由 `00-head.sh` 的 `(#@DEFINE@) PROGRAM=...` → `@PROGRAM@` 替换产生；逻辑完全相同。

## 从构建产物重新抽取

```bash
python3 - <<'EOF'
import re
s = open("vps2img-pivot").read()
body = re.search(r"cat > \S*combustion/script <<COMBUSTION\n(.*?)\nCOMBUSTION\n", s, re.S).group(1)
print(body.replace("\\$", "$"))
EOF
```

## 排查入口

```bash
journalctl -b -u combustion --no-pager        # 首启脚本输出（-x 的完整命令流）
dmesg | grep -iE 'resize device|kiwi|combustion'
ls /combustion                                # 首启成功后应不存在（分区已消费）
efibootmgr -v | grep vps2img                  # EFI 启动项
findmnt -no SOURCE,SIZE /                     # 扩容结果
```
