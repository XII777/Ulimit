package com.ulimit.app

import android.app.Application

/**
 * Installs the native crash handler before anything else runs. The
 * previous handler is always invoked afterwards, so the system crash
 * dialog / process death behave exactly as the OS expects. Also seeds
 * the [BlockEngine] with the application context (the single blocking
 * brain shared by the accessibility service and the guard service).
 */
class UlimitApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        BlockEngine.init(this)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            CrashLogStore.write(this, thread, throwable)
            previous?.uncaughtException(thread, throwable)
        }
    }
}
