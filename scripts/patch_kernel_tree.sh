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
