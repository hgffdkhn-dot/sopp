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
        dst = os.path.join(out, f)
        if not os.path.lexists(dst):
            try:
                os.symlink(src, dst)
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

# 1) Base config is the exact config read from the device (/proc/config.gz).
cp "$CFG" .config

# 2) Turn kprobes on (the original kernel had it off), and pin the version
#    suffix so vermagic stays 4.14.186-g844fd19c6 on the flashed device.
scripts/config --disable CONFIG_LOCALVERSION_AUTO
scripts/config --set-str CONFIG_LOCALVERSION "-g844fd19c6"
scripts/config --enable CONFIG_KPROBES
scripts/config --enable CONFIG_KPROBE_EVENTS
scripts/config --enable CONFIG_KRETPROBES
# The tree's compiler check for STACKPROTECTOR_STRONG is unreliable under the
# Actions toolchain; s0ppSU does not depend on it.
scripts/config --disable CONFIG_CC_STACKPROTECTOR_STRONG
scripts/config --enable CONFIG_CC_STACKPROTECTOR_NONE
make ARCH=arm64 $CROSS olddefconfig

echo "=== effective config ==="
grep -E '^CONFIG_(LOCALVERSION|KPROBES|MODVERSIONS|PREEMPT|SMP|MODULES|MODULE_UNLOAD|AUDIT)=' .config

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
