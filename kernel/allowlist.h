/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __SOPP_ALLOWLIST_H
#define __SOPP_ALLOWLIST_H

#include <linux/types.h>
#include <linux/workqueue.h>
#include "sopp.h"

#define SOPP_ALLOWLIST_PATH "/data/adb/soppsu/.allowlist"

void sopp_allowlist_init(void);
void sopp_allowlist_exit(void);

/* Query */
bool sopp_is_uid_allowed(uid_t uid);
bool sopp_uid_should_umount(uid_t uid);
bool sopp_get_app_profile(struct sopp_app_profile *profile);
bool sopp_get_allow_list(u32 *array, u32 *length, bool allowed);

/* Mutate */
bool sopp_set_app_profile(const struct sopp_app_profile *profile, bool persist);
void sopp_allow_uid(uid_t uid);
void sopp_deny_uid(uid_t uid);

/* Persistence work, scheduled on the module workqueue. */
void sopp_schedule_save(struct work_struct *work);
extern struct work_struct sopp_save_work;

struct sopp_root_profile *sopp_get_root_profile(uid_t uid);
void sopp_prune_allowlist(bool (*is_uid_valid)(uid_t, char *, void *), void *data);

#endif /* __SOPP_ALLOWLIST_H */
