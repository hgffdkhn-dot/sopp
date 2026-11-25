/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Persistent per-UID authorisation store.
 *
 * Two views are maintained: a linked list of full profiles (the source of
 * truth) and a page-sized uid bitmap for the hot path in core.c, where an
 * O(1) lookup matters more than flexibility.
 */
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/workqueue.h>

#include "allowlist.h"
#include "compat.h"
#include "manager.h"
#include "sopp.h"

#define FILE_MAGIC 0x5A0F7001U
#define FILE_FORMAT_VERSION 1
#define PROFILE_PRESERVE_UID 9999 /* NOBODY_UID */

struct sopp_perm_entry {
	struct list_head list;
	struct sopp_app_profile profile;
};

static LIST_HEAD(allow_list);
static DEFINE_MUTEX(allowlist_mutex);

/* Defined here; handler assigned in sopp_allowlist_init(). */
struct work_struct sopp_save_work;

static struct sopp_root_profile default_root_profile;
static struct sopp_non_root_profile default_non_root_profile;

/*
 * 4.14's kmalloc()/kzalloc() are __always_inline helpers that, when the size
 * is a compile-time constant (which sizeof() always is), dereference
 * kmalloc_caches[] directly instead of calling __kmalloc(). kmalloc_caches is
 * not EXPORT_SYMBOL'd, so any module built that way stays loadable but fails
 * at insmod time with an unresolved symbol. Routing through __kmalloc() (which
 * is exported) keeps the size a runtime value and avoids the reference.
 */
static void *sopp_kmalloc(size_t size, gfp_t gfp)
{
	return __kmalloc(size, gfp);
}

static void *sopp_kzalloc(size_t size, gfp_t gfp)
{
	void *p = __kmalloc(size, gfp);

	if (p)
		memset(p, 0, size);
	return p;
}

/* Fast membership test. Protected by allowlist_mutex on writers only. */
static u32 allow_uid_bitmap[PAGE_SIZE / sizeof(u32)] __read_mostly __aligned(PAGE_SIZE);

static void bitmap_set_uid(uid_t uid, bool allowed)
{
	u32 index = uid / 32;
	u32 bit = 1U << (uid % 32);

	if (index >= ARRAY_SIZE(allow_uid_bitmap))
		return;
	if (allowed)
		allow_uid_bitmap[index] |= bit;
	else
		allow_uid_bitmap[index] &= ~bit;
}

static bool bitmap_has_uid(uid_t uid)
{
	u32 index = uid / 32;
	u32 bit = 1U << (uid % 32);

	if (index >= ARRAY_SIZE(allow_uid_bitmap))
		return false;
	return !!(allow_uid_bitmap[index] & bit);
}

static void init_default_profiles(void)
{
	struct sopp_root_profile *rp = &default_root_profile;

	rp->uid = 0;
	rp->gid = 0;
	rp->groups_count = 1;
	rp->groups[0] = 0;
	rp->capabilities.effective = ~0ULL;
	rp->capabilities.permitted = ~0ULL;
	rp->capabilities.inheritable = ~0ULL;
	strcpy(rp->selinux_domain, "u:r:su:s0");
	rp->namespaces = 0;

	default_non_root_profile.umount_modules = true;
}

static struct sopp_perm_entry *find_entry(uid_t uid)
{
	struct sopp_perm_entry *entry;

	list_for_each_entry (entry, &allow_list, list) {
		if (entry->profile.current_uid == uid)
			return entry;
	}
	return NULL;
}

struct sopp_root_profile *sopp_get_root_profile(uid_t uid)
{
	struct sopp_root_profile *profile;
	struct sopp_perm_entry *entry;

	profile = sopp_kmalloc(sizeof(*profile), GFP_ATOMIC);
	if (!profile)
		return &default_root_profile;

	mutex_lock(&allowlist_mutex);
	entry = find_entry(uid);
	if (entry && entry->profile.allow_su &&
	    !entry->profile.rp_config.use_default) {
		*profile = entry->profile.rp_config.profile;
	} else {
		*profile = default_root_profile;
	}
	mutex_unlock(&allowlist_mutex);

	return profile;
}

bool sopp_is_uid_allowed(uid_t uid)
{
	/* The manager never needs an explicit grant. */
	if (sopp_is_manager_uid_valid() && sopp_get_manager_uid() == uid)
		return true;
	if (bitmap_has_uid(uid))
		return true;
	/* An allow_su=false profile is an explicit deny and wins. */
	{
		struct sopp_perm_entry *entry;
		bool found = false;
		mutex_lock(&allowlist_mutex);
		entry = find_entry(uid);
		if (entry)
			found = entry->profile.allow_su;
		mutex_unlock(&allowlist_mutex);
		return found;
	}
}

bool sopp_uid_should_umount(uid_t uid)
{
	struct sopp_perm_entry *entry;
	bool result = default_non_root_profile.umount_modules;

	if (sopp_is_manager_uid_valid() && sopp_get_manager_uid() == uid)
		return false;

	mutex_lock(&allowlist_mutex);
	entry = find_entry(uid);
	if (entry && !entry->profile.nrp_config.use_default)
		result = entry->profile.nrp_config.profile.umount_modules;
	mutex_unlock(&allowlist_mutex);

	return result;
}

static bool profile_valid(const struct sopp_app_profile *profile)
{
	if (profile->version < SOPP_APP_PROFILE_VER)
		return false;
	if (profile->rp_config.profile.groups_count > SOPP_MAX_GROUPS)
		return false;
	return true;
}

bool sopp_set_app_profile(const struct sopp_app_profile *profile, bool persist)
{
	struct sopp_perm_entry *entry;
	bool created = false;

	if (!profile_valid(profile))
		return false;

	mutex_lock(&allowlist_mutex);
	entry = find_entry(profile->current_uid);
	if (!entry) {
		entry = sopp_kzalloc(sizeof(*entry), GFP_KERNEL);
		if (!entry) {
			mutex_unlock(&allowlist_mutex);
			return false;
		}
		created = true;
	}
	entry->profile = *profile;
	if (created)
		list_add_tail(&entry->list, &allow_list);

	bitmap_set_uid(profile->current_uid, profile->allow_su);
	mutex_unlock(&allowlist_mutex);

	if (persist)
		sopp_schedule_save(&sopp_save_work);
	return true;
}

void sopp_allow_uid(uid_t uid)
{
	struct sopp_perm_entry *entry;

	mutex_lock(&allowlist_mutex);
	entry = find_entry(uid);
	if (!entry) {
		entry = sopp_kzalloc(sizeof(*entry), GFP_KERNEL);
		if (entry) {
			entry->profile.current_uid = uid;
			entry->profile.version = SOPP_APP_PROFILE_VER;
			list_add_tail(&entry->list, &allow_list);
		}
	}
	if (entry)
		entry->profile.allow_su = true;
	bitmap_set_uid(uid, true);
	mutex_unlock(&allowlist_mutex);

	sopp_schedule_save(&sopp_save_work);
}

void sopp_deny_uid(uid_t uid)
{
	struct sopp_perm_entry *entry;

	mutex_lock(&allowlist_mutex);
	entry = find_entry(uid);
	if (!entry) {
		entry = sopp_kzalloc(sizeof(*entry), GFP_KERNEL);
		if (entry) {
			entry->profile.current_uid = uid;
			entry->profile.version = SOPP_APP_PROFILE_VER;
			list_add_tail(&entry->list, &allow_list);
		}
	}
	if (entry)
		entry->profile.allow_su = false;
	bitmap_set_uid(uid, false);
	mutex_unlock(&allowlist_mutex);

	sopp_schedule_save(&sopp_save_work);
}

bool sopp_get_app_profile(struct sopp_app_profile *profile)
{
	struct sopp_perm_entry *entry;
	bool found = false;

	mutex_lock(&allowlist_mutex);
	entry = find_entry(profile->current_uid);
	if (entry) {
		*profile = entry->profile;
		found = true;
	}
	mutex_unlock(&allowlist_mutex);

	return found;
}

bool sopp_get_allow_list(u32 *array, u32 *length, bool allowed)
{
	u32 i = 0;
	struct sopp_perm_entry *entry;

	mutex_lock(&allowlist_mutex);
	list_for_each_entry (entry, &allow_list, list) {
		if (i >= 128)
			break;
		if (entry->profile.allow_su == allowed)
			array[i++] = (u32)entry->profile.current_uid;
	}
	mutex_unlock(&allowlist_mutex);

	*length = i;
	return true;
}

void sopp_prune_allowlist(bool (*is_uid_valid)(uid_t, char *, void *), void *data)
{
	struct sopp_perm_entry *entry, *tmp;

	mutex_lock(&allowlist_mutex);
	list_for_each_entry_safe (entry, tmp, &allow_list, list) {
		uid_t uid = entry->profile.current_uid;
		if (uid == PROFILE_PRESERVE_UID)
			continue;
		if (!is_uid_valid(uid, entry->profile.key, data)) {
			list_del(&entry->list);
			bitmap_set_uid(uid, false);
			kfree(entry);
		}
	}
	mutex_unlock(&allowlist_mutex);

	sopp_schedule_save(&sopp_save_work);
}

void sopp_schedule_save(struct work_struct *work)
{
	/* Work is queued on the shared ordered workqueue from main.c. */
	sopp_queue_work(work);
}

static void do_save_allowlist(struct work_struct *work)
{
	u32 magic = FILE_MAGIC;
	u32 version = FILE_FORMAT_VERSION;
	loff_t off = 0;
	struct file *fp;
	struct sopp_perm_entry *entry;

	fp = sopp_filp_open_compat(SOPP_ALLOWLIST_PATH,
				   O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (IS_ERR(fp)) {
		pr_err("soppSU: save allowlist open failed: %ld\n", PTR_ERR(fp));
		return;
	}

	sopp_kernel_write_compat(fp, &magic, sizeof(magic), &off);
	sopp_kernel_write_compat(fp, &version, sizeof(version), &off);

	mutex_lock(&allowlist_mutex);
	list_for_each_entry (entry, &allow_list, list)
		sopp_kernel_write_compat(fp, &entry->profile,
					 sizeof(entry->profile), &off);
	mutex_unlock(&allowlist_mutex);

	filp_close(fp, NULL);
}

static void do_load_allowlist(void)
{
	loff_t off = 0;
	ssize_t ret;
	struct file *fp;
	u32 magic, version;

	memset(allow_uid_bitmap, 0, sizeof(allow_uid_bitmap));

	fp = sopp_filp_open_compat(SOPP_ALLOWLIST_PATH, O_RDONLY, 0);
	if (IS_ERR(fp)) {
		pr_info("soppSU: no allowlist yet, starting clean\n");
		return;
	}

	if (sopp_kernel_read_compat(fp, &magic, sizeof(magic), &off) !=
		    sizeof(magic) ||
	    magic != FILE_MAGIC) {
		pr_err("soppSU: allowlist magic mismatch\n");
		goto out;
	}
	if (sopp_kernel_read_compat(fp, &version, sizeof(version), &off) !=
	    sizeof(version)) {
		pr_err("soppSU: allowlist version read failed\n");
		goto out;
	}

	while (true) {
		struct sopp_app_profile profile;
		ret = sopp_kernel_read_compat(fp, &profile, sizeof(profile), &off);
		if (ret != sizeof(profile))
			break;
		sopp_set_app_profile(&profile, false);
	}

out:
	filp_close(fp, NULL);
}

void sopp_allowlist_init(void)
{
	init_default_profiles();
	INIT_WORK(&sopp_save_work, do_save_allowlist);
	do_load_allowlist();
}

void sopp_allowlist_exit(void)
{
	struct sopp_perm_entry *entry, *tmp;

	mutex_lock(&allowlist_mutex);
	list_for_each_entry_safe (entry, tmp, &allow_list, list) {
		list_del(&entry->list);
		kfree(entry);
	}
	mutex_unlock(&allowlist_mutex);
}
