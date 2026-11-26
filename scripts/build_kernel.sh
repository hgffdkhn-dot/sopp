#!/usr/bin/env bash
# Build soppsu.ko + boot image from the vendor kernel tree, on GitHub Actions.
# Nothing here runs on the user's own machine or server.
set -euo pipefail

KDIR=${1:?usage: build_kernel.sh <kernel-src> <out> <repo>}
OUT=${2:?}
REPO=${3:?}
mkdir -p "$OUT"

cd "$KDIR"

# This 4.14 tree is built upstream with Clang (build.config.mtk.aarch64: CC=clang,
# clang-r383902). GCC's C99 inline semantics break legacy code here (ksm_flock
# and friends), so compile with Clang to stay close to upstream. CROSS_COMPILE
# still supplies GNU binutils; CLANG_TRIPLE targets aarch64.
export CC=clang-14
export CLANG_TRIPLE=aarch64-linux-gnu-
CROSS="CROSS_COMPILE=aarch64-linux-gnu-"

echo "=== compiler ==="
clang-14 --version | head -1

# --- 1) Base config -----------------------------------------------------------
# The tree's OWN vendor defconfig, NOT the device's runtime /proc/config.gz.
# The device config carries ~4500 options (vendor-private MTK/Xiaomi symbols
# this trimmed OSS tree has no Kconfig or code for); feeding it in makes
# olddefconfig cascade into broken dependency states. ares_user_defconfig is
# what the vendor actually built this tree with: it expands to ~1694 options and
# differs from the device config in only 72 entries, all vendor-private. It
# already enables KPROBES + SELinux + AUDIT + MODVERSIONS, which is exactly what
# s0ppSU needs.
make ARCH=arm64 $CROSS ares_user_defconfig

# --- 2) Adjustments on top of the vendor baseline -----------------------------
#  - KSU: the tree carries a throwaway KernelSU integration that also gates on
#    prctl. Drop it so it cannot fight s0ppSU for the same prctl channel.
#  - LOCALVERSION: pin to the device's exact release string so kernel and
#    modules both carry vermagic 4.14.186-g844fd19c6 and can load each other.
#  - STACKPROTECTOR_STRONG: the tree's cc-option probe fails on the Actions
#    toolchain and aborts the build; s0ppSU does not depend on it.
scripts/config --disable CONFIG_KSU
scripts/config --disable CONFIG_LOCALVERSION_AUTO
scripts/config --set-str CONFIG_LOCALVERSION "-g844fd19c6"
scripts/config --enable CONFIG_KPROBES
scripts/config --enable CONFIG_KPROBE_EVENTS
scripts/config --enable CONFIG_KRETPROBES
scripts/config --disable CONFIG_CC_STACKPROTECTOR_STRONG
scripts/config --enable CONFIG_CC_STACKPROTECTOR_NONE
# Fold the generic =m modules into the image so a freshly flashed kernel never
# asks for out-of-tree .ko files whose version no longer matches. IKHEADERS is
# excluded on purpose: it is a debug-only eBPF header bundle whose packaging
# step shells out to an unset $cpio and breaks the build.
scripts/config --enable CONFIG_TCP_CONG_WESTWOOD
scripts/config --enable CONFIG_TCP_CONG_HTCP
scripts/config --enable CONFIG_BRIDGE_NETFILTER
scripts/config --enable CONFIG_LCD_CLASS_DEVICE
scripts/config --disable CONFIG_IKHEADERS
make ARCH=arm64 $CROSS olddefconfig

echo "=== effective config ==="
grep -E '^CONFIG_(LOCALVERSION|KPROBES|KRETPROBES|MODVERSIONS|PREEMPT|SMP|MODULES|MODULE_UNLOAD|AUDIT|SECURITY_SELINUX)=' .config
echo "=== leftover =m modules (should be none) ==="
grep '=m$' .config || echo "(none)"

# --- 3) Include paths ---------------------------------------------------------
# The vendor builds this tree with an internal build system that supplies
# include paths the upstream-style Makefiles here do not carry. Two cases need
# very different treatment (full reasoning in scripts/scan_includes.py):
#  - a header name unique in the tree -> one global -idirafter list;
#  - a name present in several revisions (Mali alone ships nine copies of
#    mali_kbase_defs.h) -> injected into each subtree's own Makefile, because a
#    global list puts them all on one search path and silently picks the wrong
#    revision's struct layout.
PLATFORM=$(sed -n 's/^CONFIG_MTK_PLATFORM="\(.*\)"/\1/p' .config | head -1)
echo "=== include scan (platform=$PLATFORM) ==="
python3 "$REPO/scripts/scan_includes.py" "$KDIR" \
    "$KDIR/.sopp-include-global" "$KDIR/.sopp-include-local" "$PLATFORM"

INC=""
while IFS= read -r d; do
  [ -n "$d" ] && INC="$INC -idirafter$d"
done < "$KDIR/.sopp-include-global"

# -Wno-error: modern Clang emits warnings (strict-prototypes, format) that this
# old tree promotes to errors; upstream used an older toolchain.
# -fgnu89-inline: legacy `inline` decl-in-header/def-in-.c semantics.
export KCFLAGS="${INC} -Wno-error -fgnu89-inline ${KCFLAGS:+ $KCFLAGS}"

# --- 4) Patch the trimmed tree ------------------------------------------------
# All source adaptations live in one place; CI checkout only, upstream untouched.
bash "$REPO/scripts/patch_kernel_tree.sh" "$KDIR"

# --- 5) Build the kernel image first -----------------------------------------
# Order matters: Module.symvers is only complete once vmlinux has been linked.
# Building the module first yields a .ko whose __versions CRCs are all zero,
# which loads and then fails with "disagrees about version of symbol" on a
# MODVERSIONS kernel. The OSS tree lacks vendor-private DTS overlays
# (k6893v1_64/cust.dtsi), so we build the image only and let AnyKernel3 keep the
# device's stock dtb.
# -k keeps going after the first failing object so one CI run surfaces every
# remaining incompatibility instead of one per round trip.
make ARCH=arm64 $CROSS -j"$(nproc)" modules_prepare
make ARCH=arm64 $CROSS -j"$(nproc)" -k Image.gz || true
if [ ! -f arch/arm64/boot/Image.gz ]; then
  echo "ERROR: kernel image was not produced (see errors above)"
  exit 1
fi
cp arch/arm64/boot/Image.gz "$OUT/Image.gz"

# --- 6) External module -------------------------------------------------------
make ARCH=arm64 $CROSS -C "$KDIR" \
     M="$REPO/kernel" CONFIG_SOPP_SU=m modules
cp "$REPO/kernel/soppsu.ko" "$OUT/soppsu.ko"

# Fail loudly if the module still references anything the kernel does not
# export. modpost only warns about these; the module then dies at insmod time
# with a misleading ENOENT. Catch it here instead.
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

# --- 7) Userspace client ------------------------------------------------------
aarch64-linux-gnu-gcc -O2 -static -o "$OUT/soppctl" "$REPO/userspace/soppctl.c"

echo "=== built artifacts ==="
ls -lh "$OUT"
readelf -p .modinfo "$OUT/soppsu.ko" | grep -i vermagic
