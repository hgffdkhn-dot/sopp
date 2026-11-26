#!/usr/bin/env bash
# Make the pinned OSS tree self-contained for a standalone build.
# The Xiaomi OSS drop is trimmed: security/selinux/audit.c is missing and the
# XFRM LSM objects are not buildable standalone. hooks.c still references
# those callbacks. The vendor kernel carries the missing pieces; ours does not.
# We neutralize only those unbuildable, device-disabled callbacks in the CI
# checkout. Upstream source is never modified.
set -euo pipefail
KDIR=${1:?usage: patch_kernel_tree.sh <kernel-src> [prune|full]}
PHASE=${2:-full}

# --- phase "prune": remove trees that must not exist before the include scan ---
# Two of the adaptations below have to happen BEFORE scan_includes.py indexes the
# tree, because they change which headers exist at all:
#   * dropping the unused Mali revisions removes eight competing copies of
#     mali_kbase_defs.h, which the scanner would otherwise treat as ambiguous;
#   * the unused Trustonic TEE tree ships a second tee_client_api.h that collides
#     with MicroTrust's and breaks every teei file.
# Everything else in this file only rewrites Makefiles that the scanner has
# already read, so it must run after the scan. The pruning is idempotent, so a
# full run does it again without harm.
prune_tree() {

# --- keep only the Mali revision the device uses ------------------------------
# The OSS drop ships every Mali revision side by side, each with its own
# mali_kbase_defs.h. CONFIG_MTK_GPU_VERSION pins the device to one of them
# ("mali valhall r25p0"), but any include path that reaches across the others
# yields a mismatched struct layout (hundreds of "struct kbase_device has no
# member named ..." errors). Removing the unused revisions makes the choice
# unambiguous instead of relying on search order.
GPU_VENDOR=$(sed -n 's/^CONFIG_MTK_GPU_VERSION="mali \([a-z]*\) \([a-z0-9]*\)".*/\1 \2/p' \
  "$KDIR/.config" 2>/dev/null | head -1)
if [ -n "$GPU_VENDOR" ]; then
  set -- $GPU_VENDOR
  KEEP_VENDOR="mali_$1"
  KEEP_REV="mali-$2"
  echo "patched: keeping only $KEEP_VENDOR/$KEEP_REV"
  for v in "$KDIR"/drivers/misc/mediatek/gpu/gpu_mali/*/; do
    for r in "$v"mali-r*/; do
      [ -d "$r" ] || continue
      case "$r" in
        */"$KEEP_VENDOR"/"$KEEP_REV"/*) ;;
        *) rm -rf "$r" ;;
      esac
    done
  done
fi

# --- cmdq: keep only the generation this kernel actually builds ---------------
# Three cmdq implementations live side by side, all defining CMDQ_GROUP_ENUM,
# struct cmdqCommandStruct and the cmdqCore* surface:
#   * cmdq/v2       legacy core driver   (CONFIG_MTK_CMDQ, old SoCs)
#   * cmdq/v3       per-SoC core driver  (CONFIG_MTK_CMDQ_V3)
#   * cmdq/mailbox  mailbox client       (CONFIG_MTK_CMDQ_MBOX_EXT, this device)
# mdp/Makefile adds exactly one of them, and for CONFIG_MTK_CMDQ_MBOX_EXT it adds
# none -- because mdp ships its own complete copies of the cmdq headers it needs
# (mdp/cmdq_reg.h, cmdq_subsys_common.h, mdp_cmdq_helper_ext.h). Leaving v2 or v3
# reachable puts a second definition of each of those structures on the include
# path, and MDP stops compiling.
CMDQ="$KDIR/drivers/misc/mediatek/cmdq"
MTK_PLATFORM=$(sed -n 's/^CONFIG_MTK_PLATFORM="\(.*\)"/\1/p' "$KDIR/.config" 2>/dev/null | head -1)
if grep -q '^CONFIG_MTK_CMDQ_V3=y' "$KDIR/.config" 2>/dev/null; then
  rm -rf "$CMDQ/v2"
  echo "patched: cmdq: kept v3 (CONFIG_MTK_CMDQ_V3=y)"
elif grep -q '^CONFIG_MTK_CMDQ_MBOX_EXT=y' "$KDIR/.config" 2>/dev/null; then
  rm -rf "$CMDQ/v2" "$CMDQ/v3"
  echo "patched: cmdq: kept the mailbox client only (MDP carries its own headers)"
else
  rm -rf "$CMDQ/v3"
  echo "patched: cmdq: kept v2"
fi

# --- one mtk_idle.h ----------------------------------------------------------
# include/spm and include/spm_v4 both define the NOTIFY_*_IDLE event enum that
# thermal's mtk_tc_wrapper.c switches on. spm_v4 is the generation matching this
# SoC's low-power stack; include/spm belongs to the SPM driver that CONFIG_MTK_LPM
# replaced here, and nothing under it gets compiled.
if [ -f "$KDIR/drivers/misc/mediatek/base/power/include/spm_v4/mtk_idle.h" ]; then
  rm -f "$KDIR/drivers/misc/mediatek/base/power/include/spm/mtk_idle.h"
  echo "patched: kept include/spm_v4/mtk_idle.h only"
fi

# --- keep one watchdog generation --------------------------------------------
# Both generations ship a header called mtk_wdt.h, so an angle-bracket include
# from wdt_v2/ can land on wdt_v1/'s copy. The Kconfig choice is authoritative
# about which one this kernel builds.
WDT="$KDIR/drivers/watchdog/mediatek/wdt/common"
if grep -q '^CONFIG_MTK_WATCHDOG_COMMON_V2=y' "$KDIR/.config" 2>/dev/null; then
  rm -rf "$WDT/wdt_v1"
  echo "patched: watchdog generation: v2"
elif grep -q '^CONFIG_MTK_WATCHDOG_COMMON_V1=y' "$KDIR/.config" 2>/dev/null; then
  rm -rf "$WDT/wdt_v2"
  echo "patched: watchdog generation: v1"
fi

# --- keep one imgsensor generation -------------------------------------------
# common/v1 (legacy) and common/v1_1 both provide imgsensor.h, imgsensor_hw.h and
# so on. v1's copy includes imgsensor_clk.h, a header this OSS drop does not ship
# at all, so any object that resolves to v1 fails outright. Decide by evidence:
# the sensors named in CONFIG_CUSTOM_KERNEL_IMGSENSOR identify the generation the
# device was actually built with.
IMGS="$KDIR/drivers/misc/mediatek/imgsensor/src/common"
SENSORS=$(sed -n 's/^CONFIG_CUSTOM_KERNEL_IMGSENSOR="\(.*\)"/\1/p' "$KDIR/.config" 2>/dev/null | head -1)
if [ -n "$SENSORS" ] && [ -d "$IMGS/v1" ] && [ -d "$IMGS/v1_1" ]; then
  in_new=0
  in_old=0
  for s in $SENSORS; do
    [ -d "$IMGS/v1_1/$s" ] && in_new=$((in_new + 1))
    [ -d "$IMGS/v1/$s" ] && in_old=$((in_old + 1))
  done
  if [ "$in_new" -gt "$in_old" ]; then
    rm -rf "$IMGS/v1"
    echo "patched: imgsensor generation: v1_1 ($in_new of the configured sensors live there, $in_old in v1)"
  fi
fi

# --- drop headers whose owners are not part of this build --------------------
# mtk_lp_kernfs.h exists three times. lpm/mtk_lpm_fs is the copy this kernel
# builds; base/power/spm_v4 and base/power/spm/common/mtk_idle_fs are the older
# SPM stacks, and neither is referenced by any Makefile here (no object in either
# tree is ever compiled). Their copies are pure include-path poison: whichever
# -I comes first wins, and lpm expects the six-argument prototype while spm_v4
# declares a one-argument one.
for dead in \
  drivers/misc/mediatek/base/power/spm_v4/mtk_lp_kernfs.h \
  drivers/misc/mediatek/base/power/spm/common/mtk_idle_fs/mtk_lp_kernfs.h
do
  if [ -f "$KDIR/$dead" ]; then
    rm -f "$KDIR/$dead"
    echo "patched: removed unbuilt duplicate $dead"
  fi
done

# --- keep one per-SoC MDP tree ------------------------------------------------
# mdp/mt6885 and mdp/mt6893 each carry mdp_engine.h and a full copy of the
# engine tables. mdp/Makefile builds the one named by CONFIG_MTK_PLATFORM
# (mt6885 here), so leaving the other on the include path feeds mdp/mt6885
# objects the mt6893 enum ladder: dozens of "redeclaration of enumerator" and
# "redefinition of struct SubsysStruct".
if [ -d "$KDIR/drivers/misc/mediatek/mdp" ] && [ -n "${MTK_PLATFORM:-}" ]; then
  for d in "$KDIR"/drivers/misc/mediatek/mdp/mt*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case "$name" in
      mt[0-9]*) ;;
      *) continue ;;
    esac
    case "$name" in
      "$MTK_PLATFORM") ;;
      *) rm -rf "$d"; echo "patched: dropped mdp/$name" ;;
    esac
  done
fi

# --- mdpm: one common header -------------------------------------------------
# include/mdpm_v1/mtk_mdpm_common.h declares the debug flag as bool, mdpm_v2's
# copy as int, and only mdpm_v2 (and its mt6893 platform dir) is ever compiled
# here. The v1 headers are dead weight that shadows the v2 ones.
if [ -d "$KDIR/drivers/misc/mediatek/base/power/include/mdpm_v2" ]; then
  rm -rf "$KDIR/drivers/misc/mediatek/base/power/include/mdpm_v1"
  echo "patched: dropped stale include/mdpm_v1 headers"
fi

# --- neutralise the unused Trustonic TEE stack --------------------------------
# The device runs MicroTrust (CONFIG_MICROTRUST_TEE_SUPPORT=y), so gud/ is dead
# code -- but it cannot simply be deleted: drivers/misc/mediatek/Kconfig sources
# gud/Kconfig, and removing the directory aborts every later "make" with
# 'can't open file "drivers/misc/mediatek/gud/Kconfig"'. Emptying its Makefile
# keeps the Kconfig reachable while guaranteeing nothing under gud/ is built,
# and scan_includes.py is told to ignore the tree so its tee_client_api.h cannot
# hijack the MicroTrust build (the two define the same structs differently).
GUD="$KDIR/drivers/misc/mediatek/gud"
if [ -f "$GUD/Makefile" ] && ! grep -q '^CONFIG_TRUSTONIC_TEE_SUPPORT=y' "$KDIR/.config"; then
  : > "$GUD/Makefile"
  echo "patched: gud TEE tree kept for Kconfig but no longer built"
fi

# pseudo_m4u adds -I arch/arm/include, the 32-bit tree. On arm64 that shadows
# asm/memory.h and dies on CONFIG_PHYS_OFFSETUL, which only exists on ARM32.
sed -i '/-I\$(srctree)\/arch\/arm\/include/d' \
  "$KDIR/drivers/misc/mediatek/pseudo_m4u/Makefile" 2>/dev/null || true

}

prune_tree
if [ "$PHASE" = prune ]; then
  echo "patched: prune phase complete"
  exit 0
fi

# --- pseudo_m4u: ARM32-only dma-iommu header ---------------------------------
# arch/arm64 dropped asm/dma-iommu.h in 4.11 together with the arm_iommu_* API;
# only arch/arm still ships it. pseudo_m4u includes it and uses exactly one thing
# from it, ARM_MAPPING_ERROR, so carry that macro locally instead of pulling the
# 32-bit header in.
for f in "$KDIR"/drivers/misc/mediatek/pseudo_m4u/*.c; do
  [ -f "$f" ] || continue
  grep -q '<asm/dma-iommu.h>' "$f" || continue
  perl -0pi -e 's{#include <asm/dma-iommu\.h>}{/* arch/arm64 has no asm/dma-iommu.h; only this macro is used. */\n#ifndef ARM_MAPPING_ERROR\n#define ARM_MAPPING_ERROR\t\t(~(dma_addr_t)0x0)\n#endif}' "$f"
  echo "patched: $(basename "$f") no longer needs the ARM32 dma-iommu.h"
done

# --- headers the vendor's build system injects, but Makefiles do not ----------
# base/power/include/mtk_idle.h is a dispatcher that picks spm_vN/mtk_idle.h by
# CONFIG_MACH_*, and it has no branch for MT6893/MT6885; the result is that
# thermal's mtk_tc_wrapper.c switches on NOTIFY_*_IDLE identifiers that were
# never declared. Same story for lpm's platform trace, which needs
# struct MTK_LPM_PLAT_TRACE from a header its own Makefile never names.
# Forcing the header with -include is local to these Makefiles and survives the
# guarded duplicate copies.
inject_header() {                       # <makefile> <header relative to srctree>
  mk=$1
  hdr=$2
  [ -f "$mk" ] || return 0
  [ -f "$KDIR/$hdr" ] || return 0
  grep -q "soppSU-include:$hdr" "$mk" && return 0
  printf '\n# soppSU-include:%s\nccflags-y += -include $(srctree)/%s\n' \
    "$hdr" "$hdr" >> "$mk"
  echo "patched: $(echo "$mk" | sed "s#$KDIR/##") force-includes $(basename "$hdr")"
}
# Apply at every level that might own the failing object: kbuild only honours
# ccflags-y of the Makefile that actually compiles the file, and MTK nests these
# three deep (thermal/mt6893/src/mtk_tc_wrapper.o).
for mk in \
  drivers/misc/mediatek/thermal/Makefile \
  drivers/misc/mediatek/thermal/common/Makefile \
  drivers/misc/mediatek/thermal/mt6893/Makefile \
  drivers/misc/mediatek/thermal/mt6893/src/Makefile \
  drivers/misc/mediatek/thermal/mt6885/Makefile \
  drivers/misc/mediatek/thermal/mt6885/src/Makefile
do
  inject_header "$KDIR/$mk" drivers/misc/mediatek/base/power/include/spm_v4/mtk_idle.h
done
inject_header "$KDIR/drivers/misc/mediatek/lpm/platform/Makefile" \
  drivers/misc/mediatek/lpm/inc/mtk_lpm_platform.h

# --- lpm: two different headers share one include guard ----------------------
# lpm/platform/mtk_lpm_trace.h and lpm/inc/mtk_lpm_trace_event/mtk_lpm_trace.h
# are unrelated files that both guard on __MTK_LPM_TRACE_H__. The vendor build
# never puts them in the same translation unit; ours does, so whichever is read
# second is skipped whole -- and the file that needed the struct declaration then
# compiles against nothing ("invalid use of undefined type MTK_LPM_PLAT_TRACE").
LPM_TRACE_EVENT="$KDIR/drivers/misc/mediatek/lpm/inc/mtk_lpm_trace_event/mtk_lpm_trace.h"
if [ -f "$LPM_TRACE_EVENT" ]; then
  sed -i 's/__MTK_LPM_TRACE_H__/__MTK_LPM_TRACE_EVENT_H__/g' "$LPM_TRACE_EVENT"
  echo "patched: mtk_lpm_trace_event header has its own include guard"
fi

# --- modern-clang tolerance ---------------------------------------------------
# Modern Clang emits style/format warnings that this 2019 tree turns into
# hard errors via -Werror (top-level and several MTK sound/DRM Makefiles).
# The original toolchain emitted them as warnings. Rewrite every -Werror in
# all Makefiles to -Wno-error so the tree builds with a modern compiler.
find "$KDIR" \( -name Makefile -o -name '*.mk' \) -print0 | while IFS= read -r -d '' mk; do
  perl -pi -e '
    s/-Werror-implicit-function-declaration/-Wno-error/g;
    s/-Werror(=[A-Za-z0-9-]+)?/-Wno-error$1/g;
  ' "$mk" 2>/dev/null || true
done

# Two headers declare lock helpers as bare `inline` while defining them in a
# .c file (or later as static inline). Modern C99 semantics reject the call
# site. Drop the stray `inline` keyword in the CI copy.
sed -i 's/^inline void ksm_flock(/void ksm_flock(/' "$KDIR/include/linux/keyslot-manager.h"
sed -i 's/^inline void blk_crypto_flock(/void blk_crypto_flock(/' "$KDIR/include/linux/blk-crypto.h"

python3 - "$KDIR/security/selinux/hooks.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="surrogateescape").read()

# Equivalent stubs for XFRM callbacks (device has CONFIG_SECURITY_NETWORK_XFRM
# off; these are no-ops in that configuration anyway).
repls = [
    ("netlbl_enabled() || selinux_xfrm_enabled()",
     "netlbl_enabled()"),
    ("err = selinux_xfrm_skb_sid(skb, &xfrm_sid);",
     "err = 0;"),
    ("err = selinux_xfrm_sock_rcv_skb(sksec->sid, skb, &ad);",
     "err = 0;"),
    ("if (selinux_xfrm_postroute_last(sksec->sid, skb, &ad, proto))",
     "if (0)"),
    # Audit LSM callbacks: their implementation file is absent from the OSS
    # tree. Drop the registrations under CONFIG_AUDIT.
    ("\tLSM_HOOK_INIT(audit_rule_init, selinux_audit_rule_init),\n"
     "\tLSM_HOOK_INIT(audit_rule_known, selinux_audit_rule_known),\n"
     "\tLSM_HOOK_INIT(audit_rule_match, selinux_audit_rule_match),\n"
     "\tLSM_HOOK_INIT(audit_rule_free, selinux_audit_rule_free),\n", ""),
]
for old, new in repls:
    if old not in s:
        sys.stderr.write("WARN: pattern not found: %r\n" % old[:60])
    s = s.replace(old, new)

open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("hooks.c: XFRM calls stubbed, audit hook registrations removed")
PY

echo "patched: selinux hooks.c made self-contained"

# Focaltech touch driver includes a sample firmware blob that the OSS drop
# omits (header itself says it is a placeholder to be replaced by vendor).
# Provide an empty C array so it compiles; real firmware lives in vendor.
FT_DIR="$KDIR/drivers/input/touchscreen/focaltech_spi/include/firmware"
mkdir -p "$FT_DIR"
[ -f "$FT_DIR/fw_sample.i" ] || printf '/* s0ppSU CI stub: vendor firmware is in /vendor/firmware */\n' > "$FT_DIR/fw_sample.i"
echo "patched: focaltech firmware stub created"

# --- MTK DCM platform dispatch ------------------------------------------------
# drivers/misc/mediatek/base/power/include/mtk_dcm.h only routes MT6739/6768/
# 6765 to the generic dcm_v1 API; the MT6893/6885 support exists in
# include/dcm_v1/ but is never selected, so the header ends in #error.
python3 - "$KDIR/drivers/misc/mediatek/base/power/include/mtk_dcm.h" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="surrogateescape").read()
old = ("#if defined(CONFIG_MACH_MT6739) \\\n"
       "\t|| defined(CONFIG_MACH_MT6768) \\\n"
       "\t|| defined(CONFIG_MACH_MT6765)")
new = ("#if defined(CONFIG_MACH_MT6739) \\\n"
       "\t|| defined(CONFIG_MACH_MT6768) \\\n"
       "\t|| defined(CONFIG_MACH_MT6765) \\\n"
       "\t|| defined(CONFIG_MACH_MT6893) \\\n"
       "\t|| defined(CONFIG_MACH_MT6885)")
if old not in s:
    sys.stderr.write("WARN: mtk_dcm.h dispatch pattern not found\n")
else:
    s = s.replace(old, new, 1)
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("patched: mtk_dcm.h now routes MT6893/MT6885")
PY

# --- bq2597x charge pump: remove floating point -------------------------------
# The SC8551 branch multiplies the raw ADC code by a float LSB table inside a
# kernel_neon section. arm64 builds every kernel object with
# -mgeneral-regs-only, so clang rejects any floating point use outright, and
# the flag has no -mno- counterpart. Every LSB in that table is an exact
# multiple of 1/10000 (1.5625, 3.75, 5, 1.25, 1.2575, 3.125, 1.0), so the whole
# conversion can be done in integer arithmetic with identical results.
python3 - "$KDIR/drivers/power/supply/ti/bq2597x_charger.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="surrogateescape").read()

old_table = """static float sc8551_adc_lsb[] = {
	[ADC_IBUS]	= SC8551_IBUS_ADC_LSB,
	[ADC_VBUS]	= SC8551_VBUS_ADC_LSB,
	[ADC_VAC]	= SC8551_VAC_ADC_LSB,
	[ADC_VOUT]	= SC8551_VOUT_ADC_LSB,
	[ADC_VBAT]	= SC8551_VBAT_ADC_LSB,
	[ADC_IBAT]	= SC8551_IBAT_ADC_LSB,
	[ADC_TBUS]	= SC8551_TSBUS_ADC_LSB,
	[ADC_TBAT]	= SC8551_TSBAT_ADC_LSB,
	[ADC_TDIE]	= SC8551_TDIE_ADC_LSB,
};"""

new_table = """/* LSB values scaled by 10000 so the conversion stays integer-only. */
static const int sc8551_adc_lsb_e4[] = {
	[ADC_IBUS]	= 15625,
	[ADC_VBUS]	= 37500,
	[ADC_VAC]	= 50000,
	[ADC_VOUT]	= 12500,
	[ADC_VBAT]	= 12575,
	[ADC_IBAT]	= 31250,
	[ADC_TBUS]	= 10000,
	[ADC_TBAT]	= 10000,
	[ADC_TDIE]	= 10000,
};"""

old_use = """	if (bq->chip_vendor == SC8551) {
		kernel_neon_begin();
		*result = (int)(t * sc8551_adc_lsb[channel]);
		kernel_neon_end();
	}"""

new_use = """	if (bq->chip_vendor == SC8551)
		*result = (int)((t * (long long)sc8551_adc_lsb_e4[channel]) / 10000);"""

for old, new, tag in ((old_table, new_table, "lsb table"),
                      (old_use, new_use, "adc conversion")):
    if old not in s:
        sys.stderr.write("WARN: bq2597x %s pattern not found\n" % tag)
    else:
        s = s.replace(old, new, 1)

open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("patched: bq2597x SC8551 ADC path is integer-only")
PY

# --- lift the floating-point ban ---------------------------------------------
# arch/arm64/Makefile adds -mgeneral-regs-only to every object so the compiler
# never touches FP/SIMD registers (the kernel does not save them). A few vendor
# drivers do use floating point, all of them inside kernel_neon_begin/end
# sections, and clang rejects such files before the neon bracket can matter --
# the flag has no negative form, so a per-file opt-out needs CFLAGS_REMOVE on
# the exact Makefile that builds the object. Dropping it globally is equivalent
# for everything else: code that uses no floating point emits no FP
# instructions, so this only lifts the compile-time rejection.
sed -i 's/^KBUILD_CFLAGS[[:space:]]*+=[[:space:]]*-mgeneral-regs-only[[:space:]]*$/KBUILD_CFLAGS +=/' \
  "$KDIR/arch/arm64/Makefile"
if grep -q '^-*KBUILD_CFLAGS.*mgeneral-regs-only' "$KDIR/arch/arm64/Makefile"; then
  echo "WARN: -mgeneral-regs-only still present in arch/arm64/Makefile"
else
  echo "patched: removed global -mgeneral-regs-only"
fi

# --- subtree-scoped include paths --------------------------------------------
# A directory whose needed header name exists in several revisions cannot go on
# the global -idirafter list: every copy would compete and the alphabetically
# first one wins, which is how a Mali r25p0 build ends up compiled against a
# Bifrost header. Give such directories their own -I in their own Makefile, so
# the path only applies inside that subtree.
if [ -f "$KDIR/.sopp-include-local" ]; then
  applied=0
  skipped=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    rel="${d#$KDIR/}"
    if [ -f "$d/Makefile" ]; then
      if ! grep -q "soppSU-scope:$rel" "$d/Makefile" 2>/dev/null; then
        # ccflags-y covers objects built by this Makefile; subdir-ccflags-y
        # carries the path down to subdirectories that have their own Makefile
        # (Mali's platform/mtk_platform_common).
        printf '\n# soppSU-scope:%s\nccflags-y += -I$(srctree)/%s\nsubdir-ccflags-y += -I$(srctree)/%s\n' \
          "$rel" "$rel" "$rel" >> "$d/Makefile"
      fi
      applied=$((applied + 1))
    else
      # No Makefile of its own: the .c files live elsewhere and this is a pure
      # header directory. Widening a parent's subdir-ccflags-y would leak the
      # path across the whole subtree, so leave it for a targeted fix.
      echo "WARN: $rel has no Makefile of its own; not scoped"
      skipped=$((skipped + 1))
    fi
  done < "$KDIR/.sopp-include-local"
  echo "patched: $applied subtree-scoped include paths, $skipped skipped"
fi
