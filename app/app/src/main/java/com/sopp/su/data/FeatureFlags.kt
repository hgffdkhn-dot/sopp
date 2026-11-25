package com.sopp.su.data

/** Decoded view of the kernel feature bitmask. */
@JvmInline
value class FeatureFlags(val mask: Int) {
    fun has(flag: Int): Boolean = mask and flag != 0

    companion object {
        const val PROFILE = 1 shl 0
        const val DENYLIST = 1 shl 1
        const val SEPOLICY = 1 shl 2
        const val SU_COMPAT = 1 shl 3
        const val SAFEMODE = 1 shl 4
        const val MODULE_MOUNT = 1 shl 5
        const val KSU_COMPAT = 1 shl 6
    }
}
