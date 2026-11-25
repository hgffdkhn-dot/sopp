/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SELinux domain switching.
 *
 * This kernel's exported source tree omits the internal flask.h header, so
 * including objsec.h is not possible. The leading fields of
 * task_security_struct are ABI-stable across 4.x/5.x; we shadow just enough of
 * them to retarget the task SID. All we need from the public API is
 * security_secctx_to_secid(), which is exported.
 */
#include <linux/cred.h>
#include <linux/err.h>
#include <linux/security.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>

#include "selinux.h"

#define SOPP_MAX_DOMAIN_LEN 128

/* Mirror of the stable prefix of struct task_security_struct (objsec.h). */
struct sopp_task_security {
	u32 osid;
	u32 sid;
	u32 exec_sid;
	u32 create_sid;
	u32 keycreate_sid;
	u32 sockcreate_sid;
};

int sopp_transit_to_domain(const char *domain)
{
	struct cred *cred;
	struct sopp_task_security *tsec;
	u32 sid = 0;
	int error;

	cred = (struct cred *)__task_cred(current);
	tsec = cred->security;
	if (!tsec) {
		pr_warn("soppSU: task has no SELinux security struct\n");
		return -EINVAL;
	}

	error = security_secctx_to_secid(domain, strlen(domain), &sid);
	if (error) {
		pr_warn("soppSU: cannot resolve domain '%s': %d\n", domain, error);
		return error;
	}

	tsec->sid = sid;
	tsec->exec_sid = 0;
	tsec->create_sid = 0;
	tsec->keycreate_sid = 0;
	tsec->sockcreate_sid = 0;
	return 0;
}

void sopp_apply_selinux_rules(void)
{
	sopp_transit_to_domain(SOPP_SU_DOMAIN);
}

int sopp_handle_sepolicy(unsigned long arg3, void __user *arg4)
{
	char domain[SOPP_MAX_DOMAIN_LEN];
	long len;

	if (!arg4)
		return -EINVAL;

	len = strncpy_from_user(domain, arg4, sizeof(domain));
	if (len < 0)
		return -EFAULT;
	if (len == 0 || len >= sizeof(domain))
		return -EINVAL;

	return sopp_transit_to_domain(domain) == 0;
}
