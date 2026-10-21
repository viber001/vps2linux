# shell 片段预处理器设计

## 背景

`vps2img-pivot` 与 `vps2img-kexec` 由 `src/` 下的小片段拼装而成，早期只用 `cat`
按文件名（前导数字）顺序合并。`cat` 只能在**文件边界**处拼接，无法把一段共享正文
注入到某个 heredoc 的**正文中间**，也无法把同一份正文按程序替换成不同字面量。

最典型的例子是 Combustion 脚本：它位于**嵌套 heredoc** 内（外层 `<<'INNER'`/
`<<'DEPLOY'`，内层 `<<COMBUSTION`），而两个程序的正文前 105 行逐字节相同，仅连接名
`vps2img-pivot`/`vps2img-kexec` 不同。因此需要一个文本预处理器：在任意行注入共享
正文，并替换其中的占位符。

## 指令

指令为**行式**（允许行首空白），形如 `(#@NAME@modifier) 参数`。

`(` 是**绊线**：预处理未执行时，行首 `(` 会开启一个子 shell，随后的 `#…` 被当作注释
吞掉 `)`，导致 `(` 永不闭合，`bash` 报 `syntax error: unexpected end of file`。
递归展开产生的内容同样会被检查，因此未替换的指令不会被静默执行。

### DEFINE

```
(#@DEFINE@)        KEY=VALUE    # 定义变量，默认全局
(#@DEFINE@global)  KEY=VALUE    # 显式全局（等价于无修饰）
(#@DEFINE@local)   KEY=VALUE    # 仅当前文件作用域，不回流
```

### INCLUDE

把另一个文件的**字节**插入当前位置。

```
(#@INCLUDE@)         <path>     # 插入并替换 @KEY@；不扫描其中的指令（literal，默认）
(#@INCLUDE@literal)  <path>     # 同上，显式
(#@INCLUDE@expand)   <path>     # 另扫描一层指令
```

### HEREDOC

用另一个文件的内容作为 heredoc 正文，重建整个 heredoc。

```
(#@HEREDOC@)         <command> | <path>   # 正文替换 @KEY@；不扫描其中的指令（literal，默认）
(#@HEREDOC@literal)  <command> | <path>   # 同上，显式
(#@HEREDOC@expand)   <command> | <path>   # 另扫描正文一层指令
```

`<command>` 是完整的 heredoc 命令行，例如
`cat > /config/combustion/script <<COMBUSTION`，可按**最后一个** ` | ` 与其后的
`<path>` 切开（命令行本身不含 ` | `；`<path>` 不含 `|`、空白、换行）。

预处理器的输出为：

```
<command>
<展开后的正文>
<terminating delimiter>
```

## 语义

- **占位符**：`@KEY@`。必须先 `DEFINE` 后使用，遇到未定义即报错。
  `PROGRAM` 只是名为 `PROGRAM` 的普通变量。
  无论 `literal` 还是 `expand`，插入/正文内容里的 `@KEY@` 都会被替换；
  `expand` 与 `literal` 的区别**仅**在于是否再扫描其中的指令。
- **`expand` 只作用一层、不继承**：`expand` 仅扫描**本次插入内容**里的指令；
  内容里若还有指令，须自身再带 `expand` 才继续展开。
- **作用域**：
  - 顶层片段序列构成 **root 作用域**。
  - `INCLUDE`/`expand` 引入的文件构成 **子作用域**：能看见父作用域。
  - 无修饰或 `global` 的 `DEFINE` 写入**全局**，处处可见、跨文件保留。
  - `local` 的 `DEFINE` 只在**当前文件**（及其展开的后代）可见，离开文件即失效。
- **heredoc delimiter word**：由 `<command>` 按 POSIX quote removal 推导，支持
  `<<W`、`<<'W'`、`<<"W"`、`<<\W`、`<<-W`、以及可选的文件描述符前缀（如 `3<<W`）。

## 错误（任一即非零退出）

- 残留/无法识别的指令（未替换的 `(#@…@)`）。
- 未定义的 `@KEY@`。
- 目标文件缺失，或路径含 `|`、空白、换行。
- heredoc 正文中出现与任一**活动** delimiter 相同的整行（会提前闭合）。
- 片段目录中 basename 前导数字缺失或重复。
- 未知的指令名或修饰词（如 `(#@INCLUDE@bogus)`）。

## Makefile 集成

`tools/build.py` 接收若干片段目录，glob 出文件后按 **basename 的前导整数**升序依次
处理并输出到 stdout：

```make
vps2img-pivot:
	python3 tools/build.py --program vps2img-pivot \
		--dirs src/vps2img-pivot src/lib --assets src/assets > $@
	chmod 0755 $@
```

合并顺序沿用现有约定：lib 占 10/30/50，各程序占 00/20/40/60/80，编号不重叠。

## 组件

- `tools/build.py`：预处理器（仅标准库）。
- `src/assets/`：仅被指令引用的正文，不参与合并。
  - `combustion.sh`：Combustion 正文入口，`(#@INCLUDE@)` 依次拉入 `combustion-base.sh`、
    `combustion-user.sh`、`combustion-growroot.sh`。
  - `deploy-*.sh`：两个程序内层 deployer 的公共段（`deploy-lib.sh` 的 `table_field`/
    `partition_path`、`deploy-gpt.sh`、`deploy-combustion.sh`、`deploy-growroot.sh`、
    `deploy-efi.sh`），用 `(#@INCLUDE@expand)` 注入内层 heredoc 正文。
  - `discover-network.sh`、`validate-target.sh`：`discover_configuration` 的公共前缀与校验块。
  - `plan-base.sh`、`plan-target.sh`、`plan-disk.sh`：`print_plan` 的公共字段。
