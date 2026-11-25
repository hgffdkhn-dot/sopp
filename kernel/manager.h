/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Manager identity tracking.
 *
 * The manager UID is learned when a process proves it owns a data directory
 * matching the configured package, then prctl(BECOME_MANAGER). We cache only
 * the UID; signature verification lives in userspace (soppd) and is reported
 * to the kernel once at bootstrap.
 */
#ifndef __SOPP_MANAGER_H
#define __SOPP_MANAGER_H

#include <linux/cred.h>
#include <linux/types.h>

#define SOPP_INVALID_UID ((uid_t)-1)

#ifndef SOPP_MANAGER_PACKAGE
#define SOPP_MANAGER_PACKAGE "com.sopp.su"
#endif

extern uid_t sopp_manager_uid;

static inline bool sopp_is_manager_uid_valid(void)
{
	return sopp_manager_uid != SOPP_INVALID_UID;
}

static inline bool sopp_is_manager(void)
{
	return unlikely(sopp_manager_uid == current_uid().val);
}

static inline uid_t sopp_get_manager_uid(void)
{
	return sopp_manager_uid;
}

static inline void sopp_set_manager_uid(uid_t uid)
{
	sopp_manager_uid = uid;
}

static inline void sopp_invalidate_manager_uid(void)
{
	sopp_manager_uid = SOPP_INVALID_UID;
}

#endif /* __SOPP_MANAGER_H */
