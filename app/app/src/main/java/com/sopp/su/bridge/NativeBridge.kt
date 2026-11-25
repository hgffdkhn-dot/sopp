package com.sopp.su.bridge

/**
 * The single door to the kernel module. Everything below this class talks
 * prctl through the C shim; UI code never sees raw command numbers.
 */
class NativeBridge private constructor() {

    companion object {
        @JvmStatic external fun becomeManagerNative(pkg: String): Boolean
        @JvmStatic external fun getVersionNative(outLkm: IntArray): Int
        @JvmStatic external fun getFeaturesNative(): Int
        @JvmStatic external fun isSafeModeNative(): Boolean
        @JvmStatic external fun getUidListNative(allowed: Boolean): IntArray
        @JvmStatic external fun grantUidNative(uid: Int, allow: Boolean, pkg: String): Boolean
        @JvmStatic external fun reportEventNative(event: Int): Boolean
        @JvmStatic external fun isUidGrantedNative(uid: Int): Boolean

        init {
            System.loadLibrary("soppsu")
        }

        fun isKernelAvailable(): Boolean = getVersionNative(IntArray(1)) > 0

        fun getVersion(): Int = getVersionNative(IntArray(1))

        fun isKernelModule(): Boolean {
            val lkm = IntArray(1)
            getVersionNative(lkm)
            return lkm[0] != 0
        }

        fun getFeatures(): Int = getFeaturesNative()

        fun isSafeMode(): Boolean = isSafeModeNative()

        fun becomeManager(pkg: String): Boolean = becomeManagerNative(pkg)

        fun allowList(): IntArray = getUidListNative(true)

        fun denyList(): IntArray = getUidListNative(false)

        fun setAppAccess(uid: Int, allow: Boolean, pkg: String): Boolean =
            grantUidNative(uid, allow, pkg)

        fun isUidGranted(uid: Int): Boolean = isUidGrantedNative(uid)

        fun reportBootCompleted(): Boolean = reportEventNative(2)

        fun reportModuleMounted(): Boolean = reportEventNative(3)
    }
}
