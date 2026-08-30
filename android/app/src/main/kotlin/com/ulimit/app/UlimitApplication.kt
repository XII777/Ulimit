package com.ulimit.app

import android.app.Application

/**
 * Installs the native crash handler before anything else runs. The
 * previous handler is always invoked afterwards, so the system crash
 * dialog / process death behave exactly as the OS expects.
 */
class UlimitApplication : Application() {

    override fun onCreate() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            CrashLogStore.write(this, thread, throwable)
            previous?.uncaughtException(thread, throwable)
        }
        super.onCreate()
    }
}
