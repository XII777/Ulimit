package com.ulimit.app

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Writes native (Kotlin) crash traces into the same folder the Dart
 * crash collector uses — <dataDir>/app_flutter/crash_logs — so the
 * Settings screen reviews Dart and native crashes from one place.
 *
 * path_provider's getApplicationDocumentsDirectory() on Android is
 * context.getDir("app_flutter", MODE_PRIVATE), i.e. exactly
 * <dataDir>/app_flutter — deriving it here keeps the two sides in sync
 * without any channel round-trip.
 */
object CrashLogStore {

    private const val DIR_NAME = "app_flutter/crash_logs"
    private const val MAX_FILES = 10

    fun dir(context: Context): File =
        File(context.applicationInfo.dataDir, DIR_NAME)

    fun write(context: Context, thread: Thread, throwable: Throwable) {
        try {
            val dir = dir(context)
            if (!dir.exists()) dir.mkdirs()

            val sw = StringWriter()
            throwable.printStackTrace(PrintWriter(sw))
            val version = try {
                context.packageManager
                    .getPackageInfo(context.packageName, 0).versionName
            } catch (_: Exception) {
                "?"
            }

            val file = File(dir, "native-${System.currentTimeMillis()}.log")
            file.writeText(
                buildString {
                    appendLine(java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US).format(java.util.Date()))
                    appendLine("app: ulimit $version")
                    appendLine("thread: ${thread.name}")
                    appendLine()
                    appendLine(sw.toString())
                }
            )
            prune(dir)
        } catch (_: Throwable) {
            // Never let the collector itself crash the crash path.
        }
    }

    private fun prune(dir: File) {
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".log") } ?: return
        if (files.size <= MAX_FILES) return
        files.sortByDescending { it.name } // stamp is in the name
        for (i in MAX_FILES until files.size) {
            try {
                files[i].delete()
            } catch (_: Exception) {
            }
        }
    }
}
