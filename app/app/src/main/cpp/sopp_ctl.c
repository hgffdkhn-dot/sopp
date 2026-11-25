/*
 * Thin C shim over the prctl door. Returns true when the kernel echoed back
 * SOPP_REPLY_MAGIC.
 */
#include "sopp.h"
#include <unistd.h>
#include <stdio.h>

static bool sopp_ctl(int cmd, void *arg1, void *arg2)
{
    int32_t result = 0;
    prctl(SOPP_SU_OPTION, cmd, arg1, arg2, &result);
    return result == SOPP_REPLY_MAGIC;
}

bool sopp_become_manager(const char *pkg)
{
    char param[160];
    uid_t uid = getuid();
    unsigned int userId = uid / 100000;

    if (userId == 0)
        snprintf(param, sizeof(param), "/data/data/%s", pkg);
    else
        snprintf(param, sizeof(param), "/data/user/%u/%s", userId, pkg);

    return sopp_ctl(SOPP_CMD_BECOME_MANAGER, param, NULL);
}

int sopp_get_version(int32_t *is_lkm)
{
    int32_t version = -1;
    int32_t lkm = 0;
    sopp_ctl(SOPP_CMD_GET_VERSION, &version, &lkm);
    if (is_lkm)
        *is_lkm = lkm;
    return version;
}

uint32_t sopp_get_features(void)
{
    uint32_t features = 0;
    sopp_ctl(SOPP_CMD_GET_FEATURES, &features, NULL);
    return features;
}

bool sopp_is_safe_mode(void)
{
    return sopp_ctl(SOPP_CMD_CHECK_SAFEMODE, NULL, NULL);
}

bool sopp_get_allow_list(int32_t *uids, uint32_t *size)
{
    return sopp_ctl(SOPP_CMD_GET_ALLOW_LIST, uids, size);
}

bool sopp_get_deny_list(int32_t *uids, uint32_t *size)
{
    return sopp_ctl(SOPP_CMD_GET_DENY_LIST, uids, size);
}

bool sopp_is_uid_granted(int32_t uid, bool *granted)
{
    return sopp_ctl(SOPP_CMD_UID_GRANTED, (void *)(intptr_t)uid, granted);
}

bool sopp_set_app_profile(struct sopp_app_profile_n *profile)
{
    return sopp_ctl(SOPP_CMD_SET_APP_PROFILE, profile, NULL);
}

bool sopp_get_app_profile(struct sopp_app_profile_n *profile)
{
    return sopp_ctl(SOPP_CMD_GET_APP_PROFILE, profile, NULL);
}

bool sopp_report_event(int32_t event)
{
    return sopp_ctl(SOPP_CMD_REPORT_EVENT, (void *)(intptr_t)event, NULL);
}

bool sopp_set_sepolicy(const char *domain)
{
    return sopp_ctl(SOPP_CMD_SET_SEPOLICY, (void *)domain, NULL);
}
