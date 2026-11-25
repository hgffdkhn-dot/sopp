package com.sopp.su.data

import android.content.Context

/** Enumerates installed apps and marks the ones the kernel has granted. */
object PackageScanner {

    fun scan(context: Context, grantedUids: IntArray): List<AppInfo> {
        val pm = context.packageManager
        val granted = grantedUids.toHashSet()
        return pm.getInstalledApplications(0)
            .filter { it.uid >= 10000 }
            .map { info ->
                val label = pm.getApplicationLabel(info).toString()
                AppInfo(
                    packageName = info.packageName,
                    label = label,
                    uid = info.uid,
                    icon = pm.getApplicationIcon(info),
                    granted = info.uid in granted
                )
            }
    }
}
