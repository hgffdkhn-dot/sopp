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
# Scan for directories whose .c files include a sibling header via angle
# brackets (<foo.h> where foo.h sits in the same dir). Only those need an
# extra -I. This yields ~80 dirs (a few KB), not the entire tree.
INC=$(python3 - "$KDIR" <<'PY'
import os, re, sys
root = sys.argv[1]
pat = re.compile(r'^\s*#\s*include\s*<([^/>]+\.h)>')
dirs = set()
for base in ("drivers", "include"):
    for d, _, fs in os.walk(os.path.join(root, base)):
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
print(" ".join("-I" + d for d in sorted(dirs)))
PY
)
# -Wno-error: modern Clang emits warnings (strict-prototypes, format) that
# this old tree promotes to errors; upstream used an older toolchain.
# -fgnu89-inline: legacy `inline` decl-in-header/def-in-.c semantics.
export KCFLAGS="${INC} -Wno-error -fgnu89-inline ${KCFLAGS:+ $KCFLAGS}"

echo "=== compiler ==="
clang-14 --version | head -1

# This tree declares ksm_flock() as bare `inline` in a header but defines it
# in keyslot-manager.c. Modern compilers reject the call site (no body in
# scope). Drop the `inline` keyword in the fetched copy — the .c definition
# then provides a normal external symbol, which is semantically identical and
# matches what the original toolchain emitted. Upstream source is untouched.
sed -i 's/^inline void ksm_flock(/void ksm_flock(/' include/linux/keyslot-manager.h

# Patch the trimmed OSS tree so it builds standalone (adds the missing
# selinux/audit.c and wires it in). CI checkout only; upstream untouched.
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
# Keep SELinux XFRM off — do not let olddefconfig re-enable it. With it off,
# xfrm.h supplies static-inline stubs for all selinux_xfrm_* callbacks.
scripts/config --disable CONFIG_SECURITY_NETWORK_XFRM
make ARCH=arm64 $CROSS olddefconfig
# olddefconfig may re-enable options via dependencies; re-assert XFRM off and
# sync generated headers without another full reorder.
scripts/config --disable CONFIG_SECURITY_NETWORK_XFRM
yes '' | make ARCH=arm64 $CROSS oldconfig >/dev/null

echo "=== effective config ==="
grep -E '^CONFIG_(LOCALVERSION|KPROBES|MODVERSIONS|PREEMPT|SMP|MODULES|MODULE_UNLOAD|SECURITY_NETWORK_XFRM|AUDIT)=' .config

# 3) Prepare headers/Module.symvers for the external module build.
make ARCH=arm64 $CROSS -j"$(nproc)" modules_prepare

# 4) Build the module. CONFIG_SOPP_SU=m selects obj-m in our Makefile.
make ARCH=arm64 $CROSS -C "$KDIR" \
     M="$REPO/kernel" CONFIG_SOPP_SU=m modules
cp "$REPO/kernel/soppsu.ko" "$OUT/soppsu.ko"

# 5) Kernel image with appended dtb (non-GKI 4.14 layout).
make ARCH=arm64 $CROSS -j"$(nproc)" Image.gz-dtb
cp arch/arm64/boot/Image.gz-dtb "$OUT/Image.gz-dtb"

# 6) Static userspace client.
aarch64-linux-gnu-gcc -O2 -static -o "$OUT/soppctl" "$REPO/userspace/soppctl.c"

echo "=== built artifacts ==="
ls -lh "$OUT"
readelf -p .modinfo "$OUT/soppsu.ko" | grep -i vermagic
