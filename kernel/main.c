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
 * Kernel release string. linux_banner is exported by every kernel; the
 * obvious init_utsname()->release is not usable from a module because it
 * dereferences init_uts_ns, which has no EXPORT_SYMBOL, so insmod would
 * fail at load time with an unresolved symbol.
 */
extern const char linux_banner[];

static int __init sopp_init(void)
{
	pr_info("soppSU: booting on %s", linux_banner);

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
