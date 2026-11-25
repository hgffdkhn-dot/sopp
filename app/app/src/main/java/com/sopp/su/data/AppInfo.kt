package com.sopp.su.data

import android.graphics.drawable.Drawable

/** An installed app shown in the superuser list. */
data class AppInfo(
    val packageName: String,
    val label: String,
    val uid: Int,
    val icon: Drawable?,
    var granted: Boolean = false
)
