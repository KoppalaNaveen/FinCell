package com.example.fincell

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

object AppVisibilityManager {

    fun hideApp(context: Context) {

        val pm = context.packageManager

        pm.setComponentEnabledSetting(
            ComponentName(context, "com.example.fincell.Launcher"),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
    }

    fun showApp(context: Context) {

        val pm = context.packageManager

        pm.setComponentEnabledSetting(
            ComponentName(context, "com.example.fincell.Launcher"),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
    }
}