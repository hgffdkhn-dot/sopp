package com.sopp.su.bridge

import android.content.Context
import java.io.File

/**
 * Hot start: load the bundled module into a running kernel through an
 * existing root, with no boot image flash and no reboot.
 *
 * The module is staged in /data/local/tmp because insmod from an app-private
 * directory is denied by SELinux on most devices.
 */
object HotStart {

    private const val ASSET_NAME = "soppsu.ko"
    private const val STAGE_PATH = "/data/local/tmp/soppsu.ko"

    sealed class Outcome {
        data class Ok(val detail: String) : Outcome()
        data class Failed(val reason: String) : Outcome()
    }

    /** Must be called off the main thread: forks su and talks to the kernel. */
    fun execute(context: Context): Outcome {
        if (NativeBridge.isKernelAvailable()) {
            return Outcome.Ok("内核模块已在工作，无需热启动")
        }

        val staged = stageAsset(context) ?: return Outcome.Failed("释放内置模块失败")

        val copy = RootDetector.exec(
            arrayOf("su", "-c", "cp $staged $STAGE_PATH && chmod 0644 $STAGE_PATH")
        )
        if (copy == null) return Outcome.Failed("su 执行失败，请确认已授权 Root")

        // insmod prints errors on stderr (merged by exec); "File exists" means loaded.
        val insmod = RootDetector.exec(
            arrayOf("su", "-c", "insmod $STAGE_PATH 2>&1")
        ) ?: return Outcome.Failed("insmod 无响应")

        val kernelUp = NativeBridge.isKernelAvailable()
        if (kernelUp) {
            return Outcome.Ok(insmod.trim().ifEmpty { "模块已加载，内核门控就绪" })
        }

        val hint = when {
            insmod.contains("Invalid module format", true) ->
                "模块版本与内核不匹配：需要 4.14.186-g844fd19c6"
            insmod.contains("permission denied", true) ->
                "SELinux 拒绝加载，请检查内核是否允许 insmod"
            insmod.contains("File exists", true) ->
                "模块已加载但门控未应答，请重启 App"
            insmod.isBlank() -> "insmod 未返回信息，可能是 Root 权限不足"
            else -> insmod.trim()
        }
        return Outcome.Failed(hint)
    }

    /** Copies the asset into app-private files, returns the absolute path. */
    private fun stageAsset(context: Context): String? = try {
        val out = File(context.filesDir, ASSET_NAME)
        context.assets.open(ASSET_NAME).use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        out.setReadable(true, false)
        out.absolutePath
    } catch (t: Throwable) {
        null
    }
}
