#!/usr/bin/env bash
# Build soppsu.ko + boot image against the device's real config.
# Runs inside a full Xiaomi ares kernel source tree, on GitHub Actions.
set -euo pipefail

KDIR=${1:?usage: build_kernel.sh <kernel-src> <out> <repo>}
OUT=${2:?}
REPO=${3:?}
mkdir -p "$OUT"

CFG="$REPO/config/device.config"
[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 1; }

cd "$KDIR"

# This 4.14 tree is built upstream with Clang (see build.config.mtk.aarch64:
# CC=clang). GCC's C99 inline semantics break legacy code here (e.g.
# ksm_flock always_inline), so compile with Clang to match upstream.
# CROSS_COMPILE still supplies GNU binutils; CLANG_TRIPLE targets aarch64.
export CC=clang-14
export CLANG_TRIPLE=aarch64-linux-gnu-
CROSS="CROSS_COMPILE=aarch64-linux-gnu-"

# This trimmed 4.14 tree has countless MTK drivers that include headers by
# bare filename in angle brackets (<mtk_iommu_ext.h>, <mtk_ppm_platform.h>,
# <adsp_helper.h>, ...). Modern compilers no longer find these. Rather than
# inject thousands of -I dirs (arg/env length limit, and same-name collisions),
# flatten every header in the tree into ONE directory of symlinks and add it
# as a single -idirafter fallback. -idirafter is searched last, so it never
# shadows the correct headers the driver Makefiles already provide.
FALLBACK="$KDIR/.sopp-include-fallback"
python3 - "$KDIR" "$FALLBACK" <<'PY'
import os, sys
root, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for d, _, fs in os.walk(root):
    if out in d or "/.git" in d:
        continue
    for f in fs:
        if not f.endswith(".h"):
            continue
        src = os.path.join(d, f)
        # Flat link for bare <foo.h> includes.
        flat = os.path.join(out, f)
        if not os.path.lexists(flat):
            try:
                os.symlink(src, flat)
            except OSError:
                pass
        # Mirrored paths for <subdir/foo.h> includes. A header may be
        # referenced relative to different ancestor directories (e.g.
        # <mi_disp/foo.h> from drm/mediatek/), so link the last 2-4 path
        # components as well as the full path from source root.
        parts = os.path.relpath(src, root).split(os.sep)  # e.g. drivers/gpu/drm/mediatek/mi_disp/foo.h
        variants = set()
        for n in range(1, min(5, len(parts))):  # trailing dirs + filename
            variants.add(os.sep.join(parts[-(n+1):]))
        # full path under drivers/ and under kernel root
        variants.add(os.sep.join(parts))
        if parts[0] == "drivers":
            variants.add(os.sep.join(parts[1:]))
        for v in variants:
            mirror = os.path.join(out, v)
            if not os.path.lexists(mirror):
                try:
                    os.makedirs(os.path.dirname(mirror), exist_ok=True)
                    os.symlink(src, mirror)
                except OSError:
                    pass
PY
INC="-idirafter$FALLBACK"
# -Wno-error: modern Clang emits warnings (strict-prototypes, format) that
# this old tree promotes to errors; upstream used an older toolchain.
# -fgnu89-inline: legacy `inline` decl-in-header/def-in-.c semantics.
export KCFLAGS="${INC} -Wno-error -fgnu89-inline ${KCFLAGS:+ $KCFLAGS}"

echo "=== compiler ==="
clang-14 --version | head -1

# Patch the trimmed OSS tree so it builds standalone. All source adaptations
# live in one place; CI checkout only, upstream untouched.
bash "$REPO/scripts/patch_kernel_tree.sh" "$KDIR"

# 1) Base config: the tree's OWN vendor defconfig, NOT the device's runtime
#    /proc/config.gz. The device config carries ~4500 options (vendor-private
#    MTK/Xiaomi symbols this trimmed OSS tree has no Kconfig or code for);
#    feeding it in makes olddefconfig cascade into broken dependency states.
#    ares_user_defconfig is what the vendor actually built this tree with: it
#    expands to ~1694 options and differs from the device config in only 72
#    entries, all vendor-private. It already enables KPROBES + SELinux + AUDIT
#    + MODVERSIONS, which is exactly what s0ppSU needs.
make ARCH=arm64 $CROSS ares_user_defconfig

# 2) Adjustments on top of the vendor baseline.
#    - KSU: the tree has a throwaway KernelSU integration that also gates on
#      prctl. Drop it so it cannot fight s0ppSU for the same prctl channel.
#    - LOCALVERSION: pin to the device's exact release string so the built
#      kernel and its modules both carry vermagic 4.14.186-g844fd19c6 and can
#      load each other (and any module already on /vendor).
#    - KPROBES: already on in the defconfig; re-assert for safety.
#    - STACKPROTECTOR_STRONG: the tree's cc-option probe fails on the Actions
#      toolchain and aborts the build; s0ppSU does not depend on it.
scripts/config --disable CONFIG_KSU
scripts/config --disable CONFIG_LOCALVERSION_AUTO
scripts/config --set-str CONFIG_LOCALVERSION "-g844fd19c6"
scripts/config --enable CONFIG_KPROBES
scripts/config --enable CONFIG_KPROBE_EVENTS
scripts/config --enable CONFIG_KRETPROBES
scripts/config --disable CONFIG_CC_STACKPROTECTOR_STRONG
scripts/config --enable CONFIG_CC_STACKPROTECTOR_NONE
# The 5 =m modules in the vendor defconfig are all generic (IKHEADERS, TCP
# congestion controls, bridge netfilter, LCD class). Fold them into the image
# so a freshly flashed kernel never asks for out-of-tree .ko files whose
# version no longer matches.
scripts/config --enable CONFIG_IKHEADERS
scripts/config --enable CONFIG_TCP_CONG_WESTWOOD
scripts/config --enable CONFIG_TCP_CONG_HTCP
scripts/config --enable CONFIG_BRIDGE_NETFILTER
scripts/config --enable CONFIG_LCD_CLASS_DEVICE
make ARCH=arm64 $CROSS olddefconfig

echo "=== effective config ==="
grep -E '^CONFIG_(LOCALVERSION|KPROBES|KRETPROBES|MODVERSIONS|PREEMPT|SMP|MODULES|MODULE_UNLOAD|AUDIT|SECURITY_SELINUX)=' .config
echo "=== leftover =m modules (should be none) ==="
grep '=m$' .config || echo "(none)"

# 3) Prepare headers/Module.symvers for the external module build.
make ARCH=arm64 $CROSS -j"$(nproc)" modules_prepare

# 4) Build the module. CONFIG_SOPP_SU=m selects obj-m in our Makefile.
make ARCH=arm64 $CROSS -C "$KDIR" \
     M="$REPO/kernel" CONFIG_SOPP_SU=m modules
cp "$REPO/kernel/soppsu.ko" "$OUT/soppsu.ko"

# 5) Kernel image only. The OSS tree is missing vendor-private DTS overlays
#    (k6893v1_64/cust.dtsi), so dtbs cannot be rebuilt here. AnyKernel3 will
#    flash only the kernel and keep the device's original dtb partition.
make ARCH=arm64 $CROSS -j"$(nproc)" Image.gz
cp arch/arm64/boot/Image.gz "$OUT/Image.gz"

# 6) Static userspace client.
aarch64-linux-gnu-gcc -O2 -static -o "$OUT/soppctl" "$REPO/userspace/soppctl.c"

echo "=== built artifacts ==="
ls -lh "$OUT"
readelf -p .modinfo "$OUT/soppsu.ko" | grep -i vermagic
