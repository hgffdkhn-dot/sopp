/* SPDX-License-Identifier: GPL-2.0 */
/*
 * su command compatibility.
 *
 * A kprobe on sys_execve watches for /system/bin/su. When an authorised uid
 * executes it, the process is promoted to root before the real su binary runs.
 * This preserves the familiar `su` workflow without a setuid bit on disk.
 */
#include <linux/cred.h>
#include <linux/err.h>
#include <linux/kprobes.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#include "allowlist.h"
#include "arch.h"
#include "compat.h"
#include "sopp.h"

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)
#define SOPP_EXECVE_SYMBOL "__arm64_sys_execve"
#else
#define SOPP_EXECVE_SYMBOL "sys_execve"
#endif

#define SU_PATH "/system/bin/su"

extern void sopp_escape_to_root(void);

static void check_execve(const char __user *filename_user)
{
	char path[sizeof(SU_PATH) + 1];

	if (!filename_user)
		return;
	if (!sopp_is_uid_allowed(current_uid().val))
		return;

	memset(path, 0, sizeof(path));
	if (sopp_strncpy_from_user_nofault(path, filename_user, sizeof(path)) < 0)
		return;

	if (!memcmp(path, SU_PATH, sizeof(SU_PATH) - 1)) {
		pr_info("soppSU: su exec from uid %d, escalating\n",
			current_uid().val);
		sopp_escape_to_root();
	}
}

static int execve_handler_pre(struct kprobe *p, struct pt_regs *regs)
{
	struct pt_regs *real = SOPP_REAL_REGS(regs);
	const char __user *filename = (const char __user *)PT_REGS_PARM1(real);
	check_execve(filename);
	return 0;
}

static struct kprobe execve_kp = {
	.symbol_name = SOPP_EXECVE_SYMBOL,
	.pre_handler = execve_handler_pre,
};

void sopp_sucompat_init(void)
{
	int ret = register_kprobe(&execve_kp);
	if (ret)
		pr_warn("soppSU: execve kprobe failed: %d\n", ret);
}

void sopp_sucompat_exit(void)
{
	unregister_kprobe(&execve_kp);
}
