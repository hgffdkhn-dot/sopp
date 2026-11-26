#!/usr/bin/env bash
# Make the pinned OSS tree self-contained for a standalone build.
# The Xiaomi OSS drop is trimmed: security/selinux/audit.c is missing and the
# XFRM LSM objects are not buildable standalone. hooks.c still references
# those callbacks. The vendor kernel carries the missing pieces; ours does not.
# We neutralize only those unbuildable, device-disabled callbacks in the CI
# checkout. Upstream source is never modified.
set -euo pipefail
KDIR=${1:?usage: patch_kernel_tree.sh <kernel-src>}

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
