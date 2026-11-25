# s0ppSU

红米 K40 游戏增强版（`ares`，内核 4.14.186）适用的新一代内核级 Root 管理器。
融合 KernelSU 的内核层门控与 Magisk 的模块化模型，**独立实现，未修改任何原始内核源码**。

## 为什么需要重编内核

真机出厂内核 `# CONFIG_KPROBES is not set`，而 s0ppSU 的 prctl 门控建立在 kprobe 上，
依赖 `register_kprobe` / `unregister_kprobe`。这导致直接 `insmod` 旧模块时报
`No such file or directory`——该错误是内核 `finit_module` 对缺失符号返回的 `-ENOENT`，
并非文件路径问题，也无法靠重算 vermagic/CRC 解决。

**v1.2.0 的解法**：从官方源码重新编译内核，配置以真机 `/proc/config.gz` 为基线，
强制打开 `CONFIG_KPROBES`，并把版本尾缀锁定为 `-g844fd19c6`。新内核与模块同树编译，
vermagic 均为 `4.14.186-g844fd19c6`，符号与 CRC 自洽。刷机包用 AnyKernel3，只替换
kernel+dtb，保留 ramdisk，因此已安装的 Kitsune Magisk 不受影响。

## 目录结构

```
kernel/            内核模块源码（C/H + Kconfig/Makefile）
userspace/         soppd.sh 守护脚本、soppctl.c 客户端
app/               Kotlin 管理器工程 + 预编译 JNI so
config/            真机 config.gz 解压基线（device.config）
scripts/           build_kernel.sh / build_app.sh / pack_anykernel.sh
.github/workflows/ CI：拉取官方内核源码并按上述配置编译、打包、发布 Release
docs/              集成文档与发版说明
```

## 构建

推送到 `main` 即触发 `.github/workflows/build.yml`。全流程在 GitHub Actions 的
`ubuntu-22.04` runner 上完成：

1. 拉取 `MiCode/Xiaomi_Kernel_OpenSource` 固定 commit `49c02c2de`。
2. `build_kernel.sh`：套用 `config/device.config` → 开 KPROBES → `modules_prepare` →
   编译 `soppsu.ko`、内核 `Image.gz-dtb`、`soppctl`。
3. `pack_anykernel.sh`：打包可刷入的 AnyKernel3 zip。
4. `build_app.sh`：aapt2 → javac(R.java) → kotlinc → d8 → zipalign → apksigner，产出 APK。
5. 产物发布到 GitHub Release。

本地复现需自行准备 aarch64 交叉编译器、Android SDK 34 与 Kotlin 1.9.24，命令见各脚本。

## 内核层机制

1. **门控**：`sys_prctl` 的 kprobe 拦截 `prctl(0x5A0F7001, cmd, ...)`；仅 root 或已认证
   管理器 UID 可用，成功时回写魔数到 arg5。
2. **提权**：`GRANT_ROOT` 触发 `sopp_escape_to_root()`——直接改写 cred（uid/gid/caps/groups）、
   清除 seccomp、切入 `u:r:su:s0`，无磁盘 setuid 二进制、无需改 ramdisk。
3. **per-UID 授权 / app profile**：允许列表按 UID 生效，profile 保存在 `/data/adb/soppsu/`。
4. **DenyList**：借 `sys_setuid` kprobe 在 zygote fork 未授权 app 时卸载模块挂载。
5. **安全模式**：`input_event` kprobe 统计音量下键，连续三次触发安全模式。

详见 [docs/INTEGRATION.md](docs/INTEGRATION.md)。
