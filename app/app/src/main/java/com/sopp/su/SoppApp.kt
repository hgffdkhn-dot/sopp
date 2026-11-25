package com.sopp.su

import android.app.Application
import android.util.Log
import com.sopp.su.bridge.NativeBridge

/** Bootstrap: claim the manager identity and announce boot to the kernel. */
class SoppApp : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            if (NativeBridge.isKernelAvailable()) {
                val manager = NativeBridge.becomeManager(packageName)
                Log.i(TAG, "manager claim: $manager")
                NativeBridge.reportBootCompleted()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "kernel bridge unavailable", t)
        }
    }

    companion object {
        private const val TAG = "soppSU"
    }
}
