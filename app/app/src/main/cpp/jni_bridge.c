/*
 * JNI bridge for com.sopp.su.bridge.NativeBridge.
 * All kernel interaction funnels through the C shim in sopp_ctl.c.
 *
 * Deliberately plain C: no STL means no libc++_shared.so dependency, so the
 * library dlopen()s from a bare APK classloader namespace on any device.
 */

#include <jni.h>
#include <string.h>

#include "sopp.h"

/* Implemented in sopp_ctl.c */
bool sopp_become_manager(const char *pkg);
int sopp_get_version(int32_t *is_lkm);
uint32_t sopp_get_features(void);
bool sopp_is_safe_mode(void);
bool sopp_get_allow_list(int32_t *uids, uint32_t *size);
bool sopp_get_deny_list(int32_t *uids, uint32_t *size);
bool sopp_is_uid_granted(int32_t uid, bool *granted);
bool sopp_set_app_profile(struct sopp_app_profile_n *profile);
bool sopp_get_app_profile(struct sopp_app_profile_n *profile);
bool sopp_report_event(int32_t event);
bool sopp_set_sepolicy(const char *domain);

JNIEXPORT jboolean JNICALL
Java_com_sopp_su_bridge_NativeBridge_becomeManagerNative(JNIEnv *env, jclass clazz, jstring pkg)
{
    (void)clazz;
    const char *chars = (*env)->GetStringUTFChars(env, pkg, NULL);
    if (!chars)
        return JNI_FALSE;
    bool ok = sopp_become_manager(chars);
    (*env)->ReleaseStringUTFChars(env, pkg, chars);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_sopp_su_bridge_NativeBridge_getVersionNative(JNIEnv *env, jclass clazz, jintArray outLkm)
{
    (void)clazz;
    int32_t lkm = 0;
    int version = sopp_get_version(&lkm);
    if (outLkm && (*env)->GetArrayLength(env, outLkm) > 0) {
        jint value = (jint)lkm;
        (*env)->SetIntArrayRegion(env, outLkm, 0, 1, &value);
    }
    return (jint)version;
}

JNIEXPORT jint JNICALL
Java_com_sopp_su_bridge_NativeBridge_getFeaturesNative(JNIEnv *env, jclass clazz)
{
    (void)env;
    (void)clazz;
    return (jint)sopp_get_features();
}

JNIEXPORT jboolean JNICALL
Java_com_sopp_su_bridge_NativeBridge_isSafeModeNative(JNIEnv *env, jclass clazz)
{
    (void)env;
    (void)clazz;
    return sopp_is_safe_mode() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jintArray JNICALL
Java_com_sopp_su_bridge_NativeBridge_getUidListNative(JNIEnv *env, jclass clazz, jboolean allowed)
{
    (void)clazz;
    int32_t uids[128];
    uint32_t size = 0;
    bool ok = allowed == JNI_TRUE ? sopp_get_allow_list(uids, &size)
                                  : sopp_get_deny_list(uids, &size);
    if (!ok || size == 0)
        return (*env)->NewIntArray(env, 0);

    jintArray result = (*env)->NewIntArray(env, (jsize)size);
    (*env)->SetIntArrayRegion(env, result, 0, (jsize)size, (const jint *)uids);
    return result;
}

JNIEXPORT jboolean JNICALL
Java_com_sopp_su_bridge_NativeBridge_grantUidNative(JNIEnv *env, jclass clazz, jint uid,
                                                    jboolean allow, jstring packageName)
{
    (void)clazz;
    struct sopp_app_profile_n profile;
    memset(&profile, 0, sizeof(profile));
    profile.version = SOPP_APP_PROFILE_VER;
    profile.current_uid = (int32_t)uid;
    profile.allow_su = (allow == JNI_TRUE);

    const char *pkg = (*env)->GetStringUTFChars(env, packageName, NULL);
    if (pkg) {
        strncpy(profile.key, pkg, SOPP_MAX_PACKAGE_NAME - 1);
        (*env)->ReleaseStringUTFChars(env, packageName, pkg);
    }
    profile.rp_config.use_default = true;
    profile.nrp_config.use_default = true;
    profile.nrp_config.profile.umount_modules = true;

    return sopp_set_app_profile(&profile) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_sopp_su_bridge_NativeBridge_reportEventNative(JNIEnv *env, jclass clazz, jint event)
{
    (void)env;
    (void)clazz;
    return sopp_report_event((int32_t)event) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_sopp_su_bridge_NativeBridge_isUidGrantedNative(JNIEnv *env, jclass clazz, jint uid)
{
    (void)env;
    (void)clazz;
    bool granted = false;
    sopp_is_uid_granted((int32_t)uid, &granted);
    return granted ? JNI_TRUE : JNI_FALSE;
}
