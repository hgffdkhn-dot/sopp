/* Protocol mirror of kernel/sopp.h. Keep the two in sync. */
#ifndef SOPP_NATIVE_H
#define SOPP_NATIVE_H

#include <stdint.h>
#include <stdbool.h>
#include <sys/prctl.h>

#define SOPP_SU_OPTION   0x5A0F7001U
#define SOPP_REPLY_MAGIC 0x5A0F7001U

enum {
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
    SOPP_CMD_GET_FEATURES = 30,
    SOPP_CMD_MODULE_MOUNTED = 31,
    SOPP_CMD_GET_MODULE_STATE = 32,
};

#define SOPP_EVENT_POST_FS_DATA   1
#define SOPP_EVENT_BOOT_COMPLETED 2
#define SOPP_EVENT_MODULE_MOUNTED 3

#define SOPP_MAX_PACKAGE_NAME 256
#define SOPP_MAX_GROUPS 32
#define SOPP_SELINUX_DOMAIN 64
#define SOPP_APP_PROFILE_VER 2

struct sopp_root_profile_n {
    int32_t uid, gid;
    int32_t groups_count;
    int32_t groups[SOPP_MAX_GROUPS];
    struct { uint64_t effective, permitted, inheritable; } capabilities;
    char selinux_domain[SOPP_SELINUX_DOMAIN];
    int32_t namespaces;
};

struct sopp_non_root_profile_n {
    bool umount_modules;
};

struct sopp_app_profile_n {
    uint32_t version;
    char key[SOPP_MAX_PACKAGE_NAME];
    int32_t current_uid;
    bool allow_su;
    union {
        struct {
            bool use_default;
            char template_name[SOPP_MAX_PACKAGE_NAME];
            struct sopp_root_profile_n profile;
        } rp_config;
        struct {
            bool use_default;
            struct sopp_non_root_profile_n profile;
        } nrp_config;
    };
};

#endif /* SOPP_NATIVE_H */
