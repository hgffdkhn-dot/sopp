package com.sopp.su.bridge

import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Detects an existing root setup. File presence alone is not trusted — a su
 * binary is only counted if it actually answers with uid 0. Each probe is
 * bounded by a timeout so a half-broken root cannot freeze the UI thread.
 */
object RootDetector {

    enum class Solution(val label: String) {
        MAGISK("Magisk"), KERNELSU("KernelSU"), APATCH("APatch"),
        GENERIC("su"), NONE("未检测到 Root")
    }

    data class Result(
        val available: Boolean,
        val solution: Solution,
        val suPath: String = ""
    )

    private val SU_PATHS = arrayOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su",
        "/vendor/bin/su", "/data/adb/magisk", "/data/adb/ksu",
        "/data/adb/ap", "/data/adb/ksud"
    )

    /** Must be called off the main thread — it forks su and waits. */
    fun detect(): Result {
        val path = probeSu() ?: return Result(false, detectTrace())
        return Result(true, detectTrace(), path)
    }

    /** Runs `su -c id -u` and returns the working su path, or null. */
    private fun probeSu(): String? {
        for (path in SU_PATHS) {
            val f = File(path)
            if (!f.exists()) continue
            val uid = exec(arrayOf(path, "-c", "id -u")) ?: continue
            if (uid.trim() == "0") return path
        }
        // su may be on PATH but not at a hard-coded location
        val uid = exec(arrayOf("su", "-c", "id -u"))
        if (uid?.trim() == "0") return "su (PATH)"
        return null
    }

    private fun detectTrace(): Solution = when {
        File("/data/adb/magisk").exists() ||
            File("/data/adb/modules").exists() && File("/sbin/magisk").exists() -> Solution.MAGISK
        File("/data/adb/ksu").exists() || File("/data/adb/ksud").exists() -> Solution.KERNELSU
        File("/data/adb/ap").exists() || File("/data/adb/apd").exists() -> Solution.APATCH
        SU_PATHS.any { File(it).exists() } -> Solution.GENERIC
        else -> Solution.NONE
    }

    /** Executes a command, returns stdout+stderr, or null on timeout/failure. */
    internal fun exec(cmd: Array<String>, timeoutMs: Long = 3000): String? {
        return try {
            val p = ProcessBuilder(*cmd)
                .redirectErrorStream(true)
                .start()
            if (!p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                p.destroyForcibly()
                null
            } else {
                p.inputStream.bufferedReader().use { it.readText() }
            }
        } catch (t: Throwable) {
            null
        }
    }
}
