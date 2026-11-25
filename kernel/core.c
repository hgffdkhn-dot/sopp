/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Core privilege logic.
 *
 * A single kprobe on sys_prctl is our control door. Everything the manager
 * asks for travels through prctl(SOPP_SU_OPTION, cmd, ...); the reply slot
 * (arg5) is filled with SOPP_REPLY_MAGIC on success. A second kprobe on
 * sys_setuid implements the DenyList by detaching module mounts from
 * non-authorised app processes.
 */
#include <linux/capability.h>
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/input-event-codes.h>
#include <linux/kallsyms.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/mount.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/security.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/uidgid.h>
#include <linux/version.h>

#include "allowlist.h"
#include "arch.h"
#include "compat.h"
#include "core.h"
#include "manager.h"
#include "sopp.h"

#define FIRST_APPLICATION_UID 10000
#define LAST_APPLICATION_UID 19999
#define PER_USER_RANGE 100000

/* copy_to_user is warn_unused_result; consume it via a helper. */
static inline void sopp_reply(void __user *dst, const void *src, size_t n)
{
	if (copy_to_user(dst, src, n))
		pr_warn("soppSU: copy_to_user failed\n");
}

static bool module_mounted;
static unsigned int volumedown_presses;

static struct group_info root_groups = { .usage = ATOMIC_INIT(2) };

static inline bool uid_is_app(uid_t uid)
{
	uid_t appid = uid % PER_USER_RANGE;
	return appid >= FIRST_APPLICATION_UID && appid <= LAST_APPLICATION_UID;
}

static inline bool can_use_door(void)
{
	return current_uid().val == 0 || sopp_is_manager();
}

static void setup_groups(struct sopp_root_profile *profile, struct cred *cred)
{
	u32 i, ngroups;
	struct group_info *group_info;

	if (profile->groups_count > SOPP_MAX_GROUPS)
		return;

	if (profile->groups_count == 1 && profile->groups[0] == 0) {
		if (cred->group_info)
			put_group_info(cred->group_info);
		cred->group_info = get_group_info(&root_groups);
		return;
	}

	ngroups = profile->groups_count;
	group_info = groups_alloc(ngroups);
	if (!group_info)
		return;

	for (i = 0; i < ngroups; i++) {
		kgid_t kgid = make_kgid(current_user_ns(), profile->groups[i]);
		if (!gid_valid(kgid)) {
			put_group_info(group_info);
			return;
		}
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 9, 0)
		group_info->gid[i] = kgid;
#else
		GROUP_AT(group_info, i) = kgid;
#endif
	}
	groups_sort(group_info);
	set_groups(cred, group_info);
}

/*
 * Turn the calling process into root by editing its credentials in place.
 * This is the kernel-level advantage borrowed from KernelSU: no ramdisk patch,
 * no setuid binary on disk, and seccomp is cleared before exec.
 */
void sopp_escape_to_root(void)
{
	struct cred *cred = (struct cred *)__task_cred(current);
	struct sopp_root_profile *profile;
	u64 caps;

	if (cred->euid.val == 0)
		return;

	profile = sopp_get_root_profile(cred->uid.val);

	cred->uid.val = profile->uid;
	cred->suid.val = profile->uid;
	cred->euid.val = profile->uid;
	cred->fsuid.val = profile->uid;
	cred->gid.val = profile->gid;
	cred->sgid.val = profile->gid;
	cred->euid.val = profile->uid;
	cred->fsgid.val = profile->gid;
	cred->egid.val = profile->gid;

	/* CAP_DAC_READ_SEARCH lets the new root exec /data/adb/soppsu/soppd. */
	caps = profile->capabilities.effective | CAP_DAC_READ_SEARCH;
	memcpy(&cred->cap_effective, &caps, sizeof(cred->cap_effective));
	memcpy(&cred->cap_inheritable, &profile->capabilities.effective,
	       sizeof(cred->cap_inheritable));
	memcpy(&cred->cap_permitted, &profile->capabilities.effective,
	       sizeof(cred->cap_permitted));
	memcpy(&cred->cap_bset, &profile->capabilities.effective,
	       sizeof(cred->cap_bset));
	memcpy(&cred->cap_ambient, &profile->capabilities.effective,
	       sizeof(cred->cap_ambient));

	current_thread_info()->flags &= ~(TIF_SECCOMP | _TIF_SECCOMP);
#ifdef CONFIG_SECCOMP
	current->seccomp.mode = 0;
	current->seccomp.filter = NULL;
#endif

	setup_groups(profile, cred);

	kfree(profile);
	sopp_apply_selinux_rules();
}

static bool learn_manager_uid(void)
{
	uid_t uid = current_uid().val;
	uid_t known = sopp_get_manager_uid();

	if (!sopp_is_manager_uid_valid()) {
		sopp_set_manager_uid(uid);
		return true;
	}
	/* Same app upgraded to a new user id, e.g. 10042 -> 1010042. */
	if (uid != known && uid % PER_USER_RANGE == known)
		sopp_set_manager_uid(uid);
	return false;
}

int sopp_handle_prctl(int option, unsigned long arg2, unsigned long arg3,
		      unsigned long arg4, unsigned long arg5)
{
	u32 *reply = (u32 *)arg5;
	u32 ok = SOPP_REPLY_MAGIC;
	bool from_root, from_manager;

	if (option != SOPP_SU_OPTION)
		return 0;

	learn_manager_uid();
	from_root = current_uid().val == 0;
	from_manager = sopp_is_manager();

	if (!from_root && !from_manager)
		return 0;

	switch (arg2) {
	case SOPP_CMD_GET_VERSION: {
		u32 version = 0x00010000; /* 1.0.0 */
		u32 is_lkm = 1;
		sopp_reply((void __user *)arg3, &version, sizeof(version));
		if (arg4)
			sopp_reply((void __user *)arg4, &is_lkm, sizeof(is_lkm));
		return 0;
	}
	case SOPP_CMD_GET_FEATURES: {
		u32 features = SOPP_FEAT_PROFILE | SOPP_FEAT_DENYLIST |
			       SOPP_FEAT_SEPOLICY | SOPP_FEAT_SU_COMPAT |
			       SOPP_FEAT_SAFEMODE | SOPP_FEAT_MODULE_MOUNT |
			       SOPP_FEAT_KSU_COMPAT;
		sopp_reply((void __user *)arg3, &features, sizeof(features));
		return 0;
	}
	case SOPP_CMD_BECOME_MANAGER:
		if (from_manager)
			sopp_reply(reply, &ok, sizeof(ok));
		return 0;
	case SOPP_CMD_GRANT_ROOT:
		if (sopp_is_uid_allowed(current_uid().val)) {
			pr_info("soppSU: grant root to uid %d\n", current_uid().val);
			sopp_escape_to_root();
			sopp_reply(reply, &ok, sizeof(ok));
		}
		return 0;
	case SOPP_CMD_REPORT_EVENT:
		if (from_root && arg3 == SOPP_EVENT_MODULE_MOUNTED)
			sopp_mark_module_mounted();
		return 0;
	case SOPP_CMD_CHECK_SAFEMODE:
		if (sopp_is_safe_mode())
			sopp_reply(reply, &ok, sizeof(ok));
		return 0;
	case SOPP_CMD_SET_SEPOLICY:
		if (from_root && sopp_handle_sepolicy(arg3, (void __user *)arg4))
			sopp_reply(reply, &ok, sizeof(ok));
		return 0;
	case SOPP_CMD_UID_GRANTED:
	case SOPP_CMD_UID_SHOULD_UMOUNT: {
		uid_t target = (uid_t)arg3;
		bool value = arg2 == SOPP_CMD_UID_GRANTED
				     ? sopp_is_uid_allowed(target)
				     : sopp_uid_should_umount(target);
		sopp_reply((void __user *)arg4, &value, sizeof(value));
		sopp_reply(reply, &ok, sizeof(ok));
		return 0;
	}
	case SOPP_CMD_GET_ALLOW_LIST:
	case SOPP_CMD_GET_DENY_LIST: {
		u32 list[128];
		u32 length = 0;
		sopp_get_allow_list(list, &length,
				    arg2 == SOPP_CMD_GET_ALLOW_LIST);
		if (!copy_to_user((void __user *)arg4, &length, sizeof(length)) &&
		    !copy_to_user((void __user *)arg3, list, sizeof(u32) * length))
			sopp_reply(reply, &ok, sizeof(ok));
		return 0;
	}
	default:
		break;
	}

	/* Everything below is manager only. */
	if (!from_manager)
		return 0;

	if (arg2 == SOPP_CMD_GET_APP_PROFILE || arg2 == SOPP_CMD_SET_APP_PROFILE) {
		struct sopp_app_profile profile;
		if (copy_from_user(&profile, (void __user *)arg3, sizeof(profile)))
			return 0;
		if (arg2 == SOPP_CMD_GET_APP_PROFILE) {
			if (sopp_get_app_profile(&profile) &&
			    !copy_to_user((void __user *)arg3, &profile,
					  sizeof(profile)))
				sopp_reply(reply, &ok, sizeof(ok));
		} else if (sopp_set_app_profile(&profile, true)) {
			sopp_reply(reply, &ok, sizeof(ok));
		}
		return 0;
	}

	return 0;
}

/*
 * DenyList: when zygote forks into an unauthorised app, detach the overlay
 * mounts that host modules. Borrowed from both KernelSU and Magisk.
 */
int sopp_handle_setuid(struct cred *new, const struct cred *old)
{
#ifdef SOPP_HAS_PATH_UMOUNT
	struct path path;
	int err;
#endif

	if (!module_mounted || !new || !old)
		return 0;
	if (old->uid.val != 0)
		return 0;
	if (!uid_is_app(new->uid.val) || new->uid.val % PER_USER_RANGE > LAST_APPLICATION_UID)
		return 0;
	if (sopp_is_uid_allowed(new->uid.val))
		return 0;
	if (!sopp_uid_should_umount(new->uid.val))
		return 0;

#ifdef SOPP_HAS_PATH_UMOUNT
	err = kern_path("/system", 0, &path);
	if (!err) {
		path_umount(&path, 0);
		path_put(&path);
	}
	err = kern_path("/data/adb/modules", 0, &path);
	if (!err) {
		path_umount(&path, MNT_DETACH);
		path_put(&path);
	}
#endif
	return 0;
}

int sopp_handle_rename(struct dentry *old_dentry, struct dentry *new_dentry)
{
	char path[128];
	char *buf;

	if (!current->mm || current_uid().val != 1000 || !new_dentry)
		return 0;
	if (strcmp(new_dentry->d_iname, "packages.list"))
		return 0;

	buf = dentry_path_raw(new_dentry, path, sizeof(path));
	if (IS_ERR(buf))
		return 0;
	if (!strcmp(buf, "/system/packages.list"))
		sopp_apply_selinux_rules();
	return 0;
}

bool sopp_is_safe_mode(void)
{
	static bool safe_mode;

	if (safe_mode)
		return true;
	if (volumedown_presses >= 3) {
		safe_mode = true;
		return true;
	}
	return false;
}

int sopp_handle_input_event(unsigned int type, unsigned int code, int value)
{
	if (type == EV_KEY && code == KEY_VOLUMEDOWN && value)
		volumedown_presses++;
	return 0;
}

void sopp_mark_module_mounted(void)
{
	module_mounted = true;
}

bool sopp_is_module_mounted(void)
{
	return module_mounted;
}

/* ---- kprobe wiring ---- */

static int prctl_handler_pre(struct kprobe *p, struct pt_regs *regs)
{
	struct pt_regs *real = SOPP_REAL_REGS(regs);
	int option = (int)PT_REGS_PARM1(real);

	if (option != SOPP_SU_OPTION)
		return 0;
	return sopp_handle_prctl(option,
				 (unsigned long)PT_REGS_PARM2(real),
				 (unsigned long)PT_REGS_PARM3(real),
				 (unsigned long)PT_REGS_SYSCALL_PARM4(real),
				 (unsigned long)PT_REGS_PARM5(real));
}

static int input_handler_pre(struct kprobe *p, struct pt_regs *regs)
{
	unsigned int type = (unsigned int)PT_REGS_PARM2(regs);
	unsigned int code = (unsigned int)PT_REGS_PARM3(regs);
	int value = (int)PT_REGS_SYSCALL_PARM4(regs);
	return sopp_handle_input_event(type, code, value);
}

static struct kprobe prctl_kp = {
	.symbol_name = SOPP_PRCTL_SYMBOL,
	.pre_handler = prctl_handler_pre,
};
static struct kprobe input_kp = {
	.symbol_name = "input_event",
	.pre_handler = input_handler_pre,
};

void sopp_core_init(void)
{
	int ret;

	ret = register_kprobe(&prctl_kp);
	if (ret)
		pr_err("soppSU: prctl kprobe failed: %d\n", ret);
	else
		pr_info("soppSU: prctl door armed (%s)\n", SOPP_PRCTL_SYMBOL);

	ret = register_kprobe(&input_kp);
	if (ret)
		pr_warn("soppSU: input kprobe failed: %d (safe mode off)\n", ret);
}

void sopp_core_exit(void)
{
	unregister_kprobe(&prctl_kp);
	unregister_kprobe(&input_kp);
}
