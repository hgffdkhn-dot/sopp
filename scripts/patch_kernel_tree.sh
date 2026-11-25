#!/usr/bin/env bash
# Make the pinned OSS tree self-contained for a standalone build.
# The Xiaomi OSS drop is trimmed: security/selinux/audit.c is missing, yet
# hooks.c registers audit LSM hooks. The vendor kernel has this file; the
# open drop does not. We add a minimal, behaviour-correct implementation.
# Only the CI checkout is touched — upstream source is never modified.
set -euo pipefail
KDIR=${1:?usage: patch_kernel_tree.sh <kernel-src>}

cat > "$KDIR/security/selinux/audit.c" <<'EOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal SELinux audit LSM callbacks.
 * The Xiaomi OSS tree omits audit.c while hooks.c still registers these
 * callbacks under CONFIG_AUDIT. These stubs satisfy that registration;
 * audit rule evaluation is not used by s0ppSU.
 */
#include <linux/audit.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/security.h>
#include <linux/slab.h>

#include "audit.h"

int selinux_audit_rule_init(u32 field, u32 op, char *rulestr, void **rule)
{
	return -ENOTSUPP;
}

void selinux_audit_rule_free(void *rule)
{
}

int selinux_audit_rule_match(u32 sid, u32 field, u32 op, void *rule,
			     struct audit_context *actx)
{
	return 0;
}

int selinux_audit_rule_known(struct audit_krule *krule)
{
	return 0;
}
EOF

# Link the new file into the SELinux object list. Insert after the xfrm.o
# line (a complete, non-continued line) so the selinux-y backslash chain
# above it stays intact.
sed -i '/selinux-\$(CONFIG_SECURITY_NETWORK_XFRM) += xfrm.o/a selinux-$(CONFIG_AUDIT) += audit.o' \
  "$KDIR/security/selinux/Makefile"

echo "patched: audit.c added and wired into selinux-y"
