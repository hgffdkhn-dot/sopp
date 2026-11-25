# s0ppSU v1.2.0

内核层 Root 管理器。本版本解决真机 `No such file or directory` 加载失败：
根因是真机内核关闭了 `CONFIG_KPROBES`，导致 `register_kprobe` 符号不存在。
本版本随附**重新编译、已开启 KPROBES 的内核**，vermagic 与模块同为
`4.14.186-g844fd19c6`，ko 与内核同树编译（CRC 自洽）。

## 产物

| 文件 | 用途 |
| --- | --- |
| `soppSU-kernel-ares.zip` | AnyKernel3 刷机包：替换 kernel+dtb，保留 ramdisk 与已装的 Kitsune Magisk |
| `soppsu.ko` | 内核模块，可独立 insmod 热加载，也可随内核内置 |
| `s0ppSU-v1.2.0.apk` | Kotlin 管理器，含 Root 探测 + 热启动 |
| `soppctl` | 用户态 AArch64 命令行工具 |
| `Image.gz` | 裸内核镜像；dtb 保留原机（进阶用途） |

## 刷入步骤

1. 手机解锁 BL、已装 TWRP/自定义 recovery，且当前已有 Kitsune Magisk。
2. recovery 中刷入 `soppSU-kernel-ares.zip`。
3. 重启，确认 `uname -r` 仍为 `4.14.186-g844fd19c6`。
4. 安装 `s0ppSU-v1.2.0.apk`，状态页应显示内核能力已就绪；热启动按钮可加载模块。

## 说明

- 内核源码来自 MiCode `Xiaomi_Kernel_OpenSource`（分支 `ares-r-oss`，commit `49c02c2de`），
  未修改任何原始源码；本仓库只保存模块/管理器源码与构建脚本。
- 编译全程在 GitHub Actions 完成，不在任何个人服务器执行。
