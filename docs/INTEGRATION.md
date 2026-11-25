# s0ppSU 集成与接口说明

## 一、内核层集成

### 参考来源（只读，未修改）

- 内核源码：`~/Xiaomi_Kernel_OpenSource`（`ares-r-oss`，4.14.186）
- KSU 参考：`~/Xiaomi_Kernel_OpenSource/KernelSU/kernel/`
- 原集成点：`drivers/kernelsu -> ../KernelSU/kernel`（符号链接），`drivers/Makefile` 中
  `obj-$(CONFIG_KSU) += kernelsu/`

s0ppSU 的内核代码位于独立目录，**未改动上述任何文件**。编译时使用内核源码的一份副本
（`~/s0ppSU/kernel-build`），仅在该副本中关闭了 `CONFIG_KSU` 以避免符号冲突。

### 两种方式

**方式 A：外挂模块（本次采用）**

```sh
cd kernel
make -C <kernel-build> M=$(pwd) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CONFIG_SOPP_SU=m
insmod soppsu.ko    # 需匹配内核 vermagic 与签名
```

**方式 B：内建**

1. 拷贝 `kernel/*.c kernel/*.h kernel/Kconfig kernel/Makefile` 到 `<kernel>/drivers/soppsu/`
2. `drivers/Kconfig` 末尾：`source "drivers/soppsu/Kconfig"`
3. `drivers/Makefile` 末尾：`obj-$(CONFIG_SOPP_SU) += soppsu/`
4. defconfig：`CONFIG_SOPP_SU=y`、`CONFIG_KPROBES=y`、`CONFIG_KPROBES=y`、
   `CONFIG_SECURITY_SELINUX=y`、`CONFIG_OVERLAY_FS=y`

## 二、prctl 命令协议

调用形式：`prctl(0x5A0F7001, cmd, arg1, arg2, &reply)`
成功时 `reply == 0x5A0F7001`。仅 root 与已认证管理器 UID 可用。

| cmd | 值 | arg1 | arg2 | 说明 |
| --- | --- | --- | --- | --- |
| GET_VERSION | 0 | `int* version` | `int* is_lkm` | 版本/模块形态 |
| BECOME_MANAGER | 1 | 数据目录路径 | – | 声明管理器身份 |
| GRANT_ROOT | 2 | – | – | 当前进程提权 |
| ALLOW_UID / DENY_UID | 3/4 | uid | – | 授权/撤销 |
| GET_ALLOW_LIST | 5 | `int[128]` | `u32* len` | 查询白名单 |
| GET_APP_PROFILE | 10 | `sopp_app_profile*` | – | 读取应用配置 |
| SET_APP_PROFILE | 11 | `sopp_app_profile*` | – | 写入应用配置 |
| SET_SEPOLICY | 20 | domain 字符串 | – | 切换 SELinux 域 |
| CHECK_SAFEMODE | 21 | – | – | 安全模式探测 |
| REPORT_EVENT | 22 | event id | – | 生命周期上报 |
| GET_FEATURES | 30 | `u32* mask` | – | 能力位图 |
| MODULE_MOUNTED | 31 | – | – | 模块挂载完成通知 |

## 三、管理器 UI 说明

采用原生 Android View + 系统内置 `Theme.Material.Light.NoActionBar`，**零第三方依赖**
（无 AndroidX / Compose / Material 库），三个页面：

- **状态**：内核版本、模块形态（LKM/内建）、能力位图解码、安全模式
- **超级用户**：已安装应用列表 + 授权开关，切换即写内核白名单
- **模块**：模块挂载状态与 systemless overlay 说明

界面使用 framework 自带颜色与 `ToolBar`/`ListView`/`Switch` 控件，是 AOSP 设置应用
同源的原生观感。JNI so（`libsoppsu.so`）由 NDK 26.3 预编译置于 `jniLibs/arm64-v8a/`，
Java 仅通过 `NativeBridge` 访问，不接触命令字与结构体。

## 四、验证状态

| 项目 | 状态 |
| --- | --- |
| 原内核源码零修改 | 已确认（git status 未触碰） |
| `soppsu.ko` 交叉编译 | 通过，`vermagic 4.14.186 ... aarch64` |
| `soppctl` 交叉编译 | 通过，AArch64 ELF |
| APK 构建 | 成功，`artifacts/s0ppSU-v1.0.0.apk`，v2 签名校验通过 |
| 真机刷入/加载 | 未执行（需匹配签名内核环境） |
