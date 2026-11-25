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

# This trimmed 4.14 tree has MTK drivers that include their sibling headers
# with angle brackets (<audio_ipi_dma.h>, <adsp_helper.h>, <mtk_iommu_ext.h>).
# Modern compilers do not search the source directory for <> includes, so those
# headers must be reachable through -idirafter.
#
# A flat symlink farm of every header was tried first and is wrong: it pools
# same-named headers from unrelated subsystems into one directory, so e.g.
# fs/ocfs2/file.h and drivers/net/.../iwlwifi/fw/file.h both land as "file.h"
# and a stray reference pulls in the wrong one (ocfs2's needs handle_t). It also
# picks one of the two audio_ipi_dma.h variants arbitrarily, which then clashes
# on function signatures.
#
# Correct rule: add a directory only when the including file sits in it (so the
# sibling header is unambiguous), or when that header name exists exactly once
# in the tree. Ambiguous cross-directory names are left alone.
# -idirafter is searched after every normal -I, so these never shadow a header
# the kernel Makefiles already resolve correctly.
INC=$(python3 - "$KDIR" <<'PY'
import os, re, sys
root = sys.argv[1]
TOPS = ["arch/arm64", "drivers", "sound", "fs", "net", "security",
        "kernel", "mm", "block", "crypto", "lib", "init", "ipc"]
pat = re.compile(r'^\s*#\s*include\s*<([^>]+\.h)>', re.M)
refs = {}
for top in TOPS:
    base = os.path.join(root, top)
    if not os.path.isdir(base):
        continue
    for d, _, fs in os.walk(base):
        if "/.git" in d:
            continue
        for f in fs:
            if not f.endswith((".c", ".h")):
                continue
            try:
                txt = open(os.path.join(d, f), errors="ignore").read()
            except OSError:
                continue
            for m in pat.finditer(txt):
                refs.setdefault(m.group(1), set()).add(d)

index = {}
for top in TOPS:
    base = os.path.join(root, top)
    if not os.path.isdir(base):
        continue
    for d, _, fs in os.walk(base):
        if "/.git" in d:
            continue
        for f in fs:
            if f.endswith(".h"):
                index.setdefault(f, set()).add(d)

dirs = set()
for h, srcs in refs.items():
    cands = index.get(h, set())
    if not cands:
        continue
    same = srcs & cands          # including file lives with the header
    if same:
        dirs |= same
    elif len(cands) == 1:        # unique in the tree: unambiguous
        dirs |= cands
print(" ".join("-idirafter" + d for d in sorted(dirs)))
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

# 3) Prepare headers.
make ARCH=arm64 $CROSS -j"$(nproc)" modules_prepare

# 4) Build the kernel image FIRST. The order matters: Module.symvers is only
#    complete once vmlinux has been linked. Building the module before that
#    yields a .ko whose __versions CRCs are all zero, which loads but then
#    fails with "disagrees about version of symbol" on a MODVERSIONS kernel.
#    The OSS tree lacks vendor-private DTS overlays (k6893v1_64/cust.dtsi), so
#    we build the image only and let AnyKernel3 keep the device's stock dtb.
make ARCH=arm64 $CROSS -j"$(nproc)" Image.gz
cp arch/arm64/boot/Image.gz "$OUT/Image.gz"

# 5) Now that Module.symvers is complete, build the external module.
make ARCH=arm64 $CROSS -C "$KDIR" \
     M="$REPO/kernel" CONFIG_SOPP_SU=m modules
cp "$REPO/kernel/soppsu.ko" "$OUT/soppsu.ko"

# 6) Fail loudly if the module still references anything the kernel does not
#    export. modpost only warns about these; the module then dies at insmod
#    time with a misleading ENOENT. Catch it here instead.
echo "=== undefined symbols in soppsu.ko ==="
nm -u "$OUT/soppsu.ko" | awk '{print $2}' | grep -v '^$' | sort -u > /tmp/sopp-undef.txt
missing=""
while read -r sym; do
  [ -z "$sym" ] && continue
  awk -v s="$sym" '$2 == s { found = 1; exit } END { exit !found }' \
      "$KDIR/Module.symvers" || missing="$missing $sym"
done < /tmp/sopp-undef.txt
if [ -n "$missing" ]; then
  echo "ERROR: module references non-exported symbols:$missing"
  exit 1
fi
echo "all $(wc -l < /tmp/sopp-undef.txt) undefined symbols are exported by the kernel"

# 7) Static userspace client.
aarch64-linux-gnu-gcc -O2 -static -o "$OUT/soppctl" "$REPO/userspace/soppctl.c"

echo "=== built artifacts ==="
ls -lh "$OUT"
readelf -p .modinfo "$OUT/soppsu.ko" | grep -i vermagic
