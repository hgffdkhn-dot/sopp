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

# Legacy MTK drivers include sibling headers with angle brackets
# (<clk-mux.h>, <dt_idle_states.h>, <helio-dvfsrc-qos.h>). Modern compilers no
# longer search the source dir implicitly. Inject the known directories;
# keep the list short so the environment size stays bounded.
# Legacy MTK drivers include sibling headers via angle brackets
# (<clk-mux.h>, <adsp_helper.h>, ...). Modern compilers no longer search the
# source dir implicitly. Scan only drivers/ (NOT include/) for such cases:
# scanning include/ would inject -I paths containing same-named headers such
# as security.h/xfrm.h ahead of the correct ones and break SELinux.
INC=$(python3 - "$KDIR" <<'PY'
import os, re, sys
root = sys.argv[1]
pat = re.compile(r'^\s*#\s*include\s*<([^/>]+\.h)>')
# Headers that clash with kernel-wide names; never inject their directories.
blacklist_names = {"types.h", "sched.h", "security.h", "xfrm.h", "audit.h", "kernel.h"}
dirs = set()
for d, _, fs in os.walk(os.path.join(root, "drivers")):
    if any(os.path.exists(os.path.join(d, h)) for h in blacklist_names):
        continue
    for f in fs:
        if not f.endswith((".c", ".h")):
            continue
        try:
            lines = open(os.path.join(d, f), errors="ignore").read().splitlines()
        except OSError:
            continue
        for ln in lines:
            m = pat.match(ln)
            if m and os.path.exists(os.path.join(d, m.group(1))):
                dirs.add(d)
                break
# Use -idirafter (not -I): these are fallback dirs. -I would inject common-named
# headers (queue.h etc.) ahead of the correct ones and break other drivers.
# Cross-directory angle-bracket includes that the sibling scan cannot see
# (e.g. mt_iommu.h -> <mtk_iommu_ext.h> which lives in drivers/iommu).
extra = ["drivers/iommu", "drivers/gpu/drm/mediatek", "drivers/gpu/drm/panel"]
all_dirs = sorted(dirs | {os.path.join(root, e) for e in extra})
print(" ".join("-idirafter" + d for d in all_dirs))
PY
)
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
