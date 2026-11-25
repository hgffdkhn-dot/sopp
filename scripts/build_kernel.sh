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

# Legacy MTK 4.14 drivers use angle-bracket includes for headers sitting next
# to them (e.g. <clk-mux.h>, <dt_idle_states.h>). Old GCC searched the source
# dir implicitly; modern GCC does not. Inject those dirs without touching the
# upstream source tree.
export KCFLAGS="-I$KDIR/drivers/clk/mediatek -I$KDIR/drivers/cpuidle ${KCFLAGS:-}"

# 1) Base config is the exact config read from the device (/proc/config.gz).
cp "$CFG" .config

# 2) Turn kprobes on (the original kernel had it off), and pin the version
#    suffix so vermagic stays 4.14.186-g844fd19c6 on the flashed device.
scripts/config --disable CONFIG_LOCALVERSION_AUTO
scripts/config --set-str CONFIG_LOCALVERSION "-g844fd19c6"
scripts/config --enable CONFIG_KPROBES
scripts/config --enable CONFIG_KPROBE_EVENTS
scripts/config --enable CONFIG_KRETPROBES
make ARCH=arm64 olddefconfig

echo "=== effective config ==="
grep -E '^CONFIG_(LOCALVERSION|KPROBES|MODVERSIONS|PREEMPT|SMP|MODULES|MODULE_UNLOAD)=' .config

# 3) Prepare headers/Module.symvers for the external module build.
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" modules_prepare

# 4) Build the module. CONFIG_SOPP_SU=m selects obj-m in our Makefile.
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -C "$KDIR" \
     M="$REPO/kernel" CONFIG_SOPP_SU=m modules
cp "$REPO/kernel/soppsu.ko" "$OUT/soppsu.ko"

# 5) Kernel image with appended dtb (non-GKI 4.14 layout).
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image.gz-dtb
cp arch/arm64/boot/Image.gz-dtb "$OUT/Image.gz-dtb"

# 6) Static userspace client.
aarch64-linux-gnu-gcc -O2 -static -o "$OUT/soppctl" "$REPO/userspace/soppctl.c"

echo "=== built artifacts ==="
ls -lh "$OUT"
readelf -p .modinfo "$OUT/soppsu.ko" | grep -i vermagic
