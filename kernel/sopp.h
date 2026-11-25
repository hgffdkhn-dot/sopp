/* SPDX-License-Identifier: GPL-2.0 */
/*
 * s0ppSU - next generation kernel-level root manager.
 *
 * Protocol shared between the kernel module and userspace. The wire format is
 * intentionally kept binary and stable: userspace talks to us exclusively
 * through prctl(SOPP_SU_OPTION, cmd, arg1, arg2, &reply).
 */
#ifndef __SOPP_SU_H
#define __SOPP_SU_H

#include <linux/types.h>

/* The magic prctl option. Mirrors the idea behind KernelSU's 0xDEADBEEF door. */
#define SOPP_SU_OPTION 0x5A0F7001U

/* Userspace sends this back in the reply slot on success. */
#define SOPP_REPLY_MAGIC 0x5A0F7001U

/*
 * Command IDs. 0x00-0x1f are the stable public ABI; everything above is
 * reserved for internal events reported by the in-kernel helpers.
 */
enum sopp_cmd {
	SOPP_CMD_GET_VERSION = 0,
	SOPP_CMD_BECOME_MANAGER = 1,
	SOPP_CMD_GRANT_ROOT = 2,

	SOPP_CMD_ALLOW_UID = 3,
	SOPP_CMD_DENY_UID = 4,
	SOPP_CMD_GET_ALLOW_LIST = 5,
	SOPP_CMD_GET_DENY_LIST = 6,

	SOPP_CMD_GET_APP_PROFILE = 10,
	SOPP_CMD_SET_APP_PROFILE = 11,
	SOPP_CMD_UID_GRANTED = 12,
	SOPP_CMD_UID_SHOULD_UMOUNT = 13,

	SOPP_CMD_SET_SEPOLICY = 20,
	SOPP_CMD_CHECK_SAFEMODE = 21,
	SOPP_CMD_REPORT_EVENT = 22,

	/* Magisk-flavoured additions: module state + property override count. */
	SOPP_CMD_GET_FEATURES = 30,
	SOPP_CMD_MODULE_MOUNTED = 31,
	SOPP_CMD_GET_MODULE_STATE = 32,
};

/* Feature bits returned by SOPP_CMD_GET_FEATURES. */
#define SOPP_FEAT_PROFILE       (1U << 0)  /* per-app root profile        */
#define SOPP_FEAT_DENYLIST      (1U << 1)  /* umount modules for uid      */
#define SOPP_FEAT_SEPOLICY      (1U << 2)  /* runtime sepolicy injection  */
#define SOPP_FEAT_SU_COMPAT     (1U << 3)  /* su executable hook          */
#define SOPP_FEAT_SAFEMODE      (1U << 4)  /* volume-key safe mode        */
#define SOPP_FEAT_MODULE_MOUNT  (1U << 5)  /* Magisk-style module mounts  */
#define SOPP_FEAT_KSU_COMPAT    (1U << 6)  /* ABI compatible with KSU cli */

/* Events accepted by SOPP_CMD_REPORT_EVENT. */
#define SOPP_EVENT_POST_FS_DATA   1
#define SOPP_EVENT_BOOT_COMPLETED 2
#define SOPP_EVENT_MODULE_MOUNTED 3

#define SOPP_MAX_PACKAGE_NAME 256
#define SOPP_MAX_GROUPS       32
#define SOPP_SELINUX_DOMAIN   64

/*
 * What a granted uid becomes after escape_to_root(). Kept layout-compatible
 * with KSU's root_profile so existing front-ends can be reused when wanted.
 */
struct sopp_root_profile {
	int32_t uid;
	int32_t gid;
	int32_t groups_count;
	int32_t groups[SOPP_MAX_GROUPS];
	struct {
		u64 effective;
		u64 permitted;
		u64 inheritable;
	} capabilities;
	char selinux_domain[SOPP_SELINUX_DOMAIN];
	int32_t namespaces;
};

struct sopp_non_root_profile {
	bool umount_modules;
};

struct sopp_app_profile {
	u32 version;
	char key[SOPP_MAX_PACKAGE_NAME];
	int32_t current_uid;
	bool allow_su;
	union {
		struct {
			bool use_default;
			char template_name[SOPP_MAX_PACKAGE_NAME];
			struct sopp_root_profile profile;
		} rp_config;
		struct {
			bool use_default;
			struct sopp_non_root_profile profile;
		} nrp_config;
	};
};

#define SOPP_APP_PROFILE_VER 2

bool sopp_queue_work(struct work_struct *work);

#endif /* __SOPP_SU_H */
