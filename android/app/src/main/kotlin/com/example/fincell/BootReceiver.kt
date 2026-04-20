package com.example.fincell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {

        try {

            val action = intent?.action ?: return

            if (action == Intent.ACTION_BOOT_COMPLETED ||
                action == Intent.ACTION_LOCKED_BOOT_COMPLETED) {

                Log.d("FinCell", "Boot completed received")

                val prefs = context.getSharedPreferences(
                    "fincell_prefs",
                    Context.MODE_PRIVATE
                )

                val isLost = prefs.getBoolean("is_lost", false)
                val code = prefs.getString("device_code", null)

                if (!isLost || code.isNullOrEmpty()) {
                    Log.d("FinCell", "Tracking not enabled, skipping restart")
                    return
                }

                Log.d("FinCell", "Restarting tracking service after boot")

                val serviceIntent = Intent(
                    context,
                    LocationForegroundService::class.java
                ).apply {
                    putExtra("code", code)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            }

        } catch (e: Exception) {

            Log.e("FinCell", "BootReceiver error", e)
        }
    }
}