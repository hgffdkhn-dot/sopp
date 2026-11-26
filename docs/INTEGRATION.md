# s0ppSU 集成与接口说明

## 一、构建方式

全部编译在 GitHub Actions（`ubuntu-22.04`）完成，不使用本机或自建服务器。
工作流：`.github/workflows/build.yml`，产物见 Release。

### 内核源码

| 项 | 值 |
| --- | --- |
| 仓库 | `MiCode/Xiaomi_Kernel_OpenSource` |
| 分支 | `ares-r-oss` |
| commit | `49c02c2de185e3e93951fdad6c4dd9caf453523a` |
| 版本 | Linux 4.14.186（真机 `uname -r` = `4.14.186-g844fd19c6`） |

源码以只读方式使用：CI 检出后按脚本打补丁，补丁只作用于 CI 的检出副本，
不改动上游仓库，也不改动用户服务器上的任何源码。

### 三个脚本的分工

| 脚本 | 职责 |
| --- | --- |
| `scripts/build_kernel.sh` | 配置基线（`ares_user_defconfig`）→ 裁剪 → 扫描头文件 → 编译 `Image.gz` → 编译 `soppsu.ko` → 未导出符号门禁 |
| `scripts/patch_kernel_tree.sh` | 全部源码适配：分两阶段，`prune` 在扫描前删除不该存在的重复驱动树，`full` 在扫描后改写 Makefile 与少量源码 |
| `scripts/scan_includes.py` | 计算厂商内部构建系统才会提供、而 OSS 树 Makefile 缺失的头文件搜索路径；同名头文件按子树作用域注入，避免 Mali/cmdq 那类"选错版本"的问题 |

关键配置开关（相对源码自带 defconfig）：

```
CONFIG_KSU=n                        # 源码里的试验性 KSU 集成，会和 s0ppSU 抢 prctl
CONFIG_LOCALVERSION="-g844fd19c6"    # 与真机 vermagic 对齐
CONFIG_KPROBES=y / KPROBE_EVENTS=y / KRETPROBES=y
CONFIG_CC_STACKPROTECTOR_STRONG=n   # 编译器探测失败，改用 NONE
```

### 模块

```sh
make -C <kernel-src> M=<repo>/kernel ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- CONFIG_SOPP_SU=m
```

模块必须与内核同树、同一次编译产出：`Module.symvers` 里的 CRC 才会与内核一致，
否则 insmod 会以 `disagrees about version of symbol` 失败。构建脚本在镜像链接完成后
才编模块，并逐个比对 `nm -u soppsu.ko` 与 `Module.symvers`，有任何一个未导出符号就直接失败
（这类问题在设备上表现为误导性的 `No such file or directory`）。

## 二、prctl 命令协议

调用形式：`prctl(0x5A0F7001, cmd, arg1, arg2, &reply)`，成功时 `reply == 0x5A0F7001`。
仅 root 与已认证管理器 UID 可用。

| cmd | 值 | arg1 | arg2 | 说明 |
| --- | --- | --- | --- | --- |
| GET_VERSION | 0 | `int* version` | `int* is_lkm` | 版本 / 模块形态 |
| BECOME_MANAGER | 1 | 数据目录路径 | – | 声明管理器身份 |
| GRANT_ROOT | 2 | – | – | 当前进程提权 |
| GET_ALLOW_LIST | 5 | `int[128]` | `u32* len` | 查询白名单 |
| GET_DENY_LIST | 6 | `int[128]` | `u32* len` | 查询黑名单 |
| GET_APP_PROFILE | 10 | `sopp_app_profile*` | – | 读取应用配置 |
| SET_APP_PROFILE | 11 | `sopp_app_profile*` | – | 写入应用配置 |
| UID_GRANTED | 12 | uid | `bool*` | 是否已授权 |
| UID_SHOULD_UMOUNT | 13 | uid | `bool*` | 是否需卸载模块 |
| SET_SEPOLICY | 20 | domain 字符串 | – | 切换 SELinux 域 |
| CHECK_SAFEMODE | 21 | – | – | 安全模式探测 |
| REPORT_EVENT | 22 | event id | – | 生命周期上报 |
| GET_FEATURES | 30 | `u32* mask` | – | 能力位图 |

内核侧入口是 `sys_prctl` 上的 kprobe（4.14 无 `__arm64_sys_` 前缀），
提权通过就地改写 `cred` 完成，不落地 setuid 二进制。

## 三、管理器 UI

原生 Android View + 系统 `Theme.Material.Light.NoActionBar`，零第三方依赖
（无 AndroidX / Compose / Material 库），三个页面：

- **状态**：内核版本、模块形态（LKM / 内建）、能力位图、安全模式、热启动
- **超级用户**：已安装应用列表 + 授权开关，切换即写内核白名单
- **模块**：模块挂载状态与 systemless overlay 说明

`libsoppsu.so` 为纯 C 实现（无 STL，因此不依赖 `libc++_shared.so`），
Java/Kotlin 侧只经 `NativeBridge` 访问，不接触命令字与结构体。

热启动（`HotStart.kt`）走已装的 Magisk su：把 APK 内置的 `soppsu.ko` 释放到
应用私有目录 → `su -c cp` 到 `/data/local/tmp` → `insmod`，随后用
`GET_VERSION` 判断门控是否就绪。失败时按 insmod 的 stderr 给出可操作的提示
（vermagic 不匹配 / SELinux 拒绝 / 已加载）。

## 四、验证状态

| 项目 | 状态 |
| --- | --- |
| 原内核源码零修改 | 已确认（补丁只作用于 CI 检出副本） |
| 内核镜像 + 模块同树编译 | 进行中（见 Actions 运行记录） |
| `soppsu.ko` 未导出符号门禁 | 脚本已内置 |
| APK 构建 | 脚本已就绪（`scripts/build_app.sh`，无 Gradle） |
| 真机刷入 | 待执行 |
