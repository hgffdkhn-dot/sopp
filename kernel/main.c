/* SPDX-License-Identifier: GPL-2.0 */
/*
 * s0ppSU kernel module entry point.
 *
 * Subsystem order matters: the workqueue must exist before the allowlist,
 * and the core prctl door is armed last so userspace never observes a
 * half-initialised manager.
 */
#include <linux/init.h>
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/utsname.h>
#include <linux/version.h>
#include <linux/workqueue.h>

#include "allowlist.h"
#include "core.h"
#include "manager.h"

void sopp_sucompat_init(void);
void sopp_sucompat_exit(void);

MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("s0pp");
MODULE_DESCRIPTION("s0ppSU - next generation kernel root manager");

uid_t sopp_manager_uid = SOPP_INVALID_UID;

static struct workqueue_struct *sopp_wq;

bool sopp_queue_work(struct work_struct *work)
{
	if (!sopp_wq)
		return false;
	return queue_work(sopp_wq, work);
}

/*
 * Kernel release string for the boot log. init_uts_ns is EXPORT_SYMBOL_GPL, so
 * a GPL module may dereference it through init_utsname(). linux_banner is the
 * tempting alternative and is wrong here: it is the one symbol in init/version.c
 * with no EXPORT_SYMBOL at all, so referencing it links cleanly and then fails
 * at insmod with an unresolved symbol.
 */
static int __init sopp_init(void)
{
	pr_info("soppSU: booting on %s", init_utsname()->release);

	sopp_wq = alloc_ordered_workqueue("soppsu_wq", WQ_UNBOUND);
	if (!sopp_wq)
		return -ENOMEM;

	sopp_allowlist_init();
	sopp_core_init();
	sopp_sucompat_init();

	pr_info("soppSU: ready\n");
	return 0;
}

static void __exit sopp_exit(void)
{
	sopp_sucompat_exit();
	sopp_core_exit();
	sopp_allowlist_exit();
	destroy_workqueue(sopp_wq);
	pr_info("soppSU: unloaded\n");
}

module_init(sopp_init);
module_exit(sopp_exit);
