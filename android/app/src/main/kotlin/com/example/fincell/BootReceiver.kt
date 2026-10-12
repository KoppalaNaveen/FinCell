package com.example.fincell

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.Data
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager

class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        try {
            val action = intent?.action ?: return

            if (action == Intent.ACTION_BOOT_COMPLETED ||
                action == Intent.ACTION_LOCKED_BOOT_COMPLETED) {

                Log.d("FinCell_Boot", "Boot completed event received: $action")

                // Step 1: Check system Location Service state on reboot
                LocationReminderManager.checkAndNotify(context)

                val prefs = context.getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
                val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

                var code = prefs.getString("device_code", null)
                if (code.isNullOrEmpty()) {
                    val flutterCode = flutterPrefs.getString("flutter.uniqueCode", null)
                    if (!flutterCode.isNullOrEmpty()) {
                        code = flutterCode.replace("\"", "").trim()
                    }
                }

                if (code.isNullOrEmpty()) {
                    Log.d("FinCell_Boot", "No device code registered, skipping boot service restart")
                    return
                }

                // Check if service is already running to prevent duplicates
                if (isServiceRunning(context, LocationForegroundService::class.java)) {
                    Log.d("FinCell_Boot", "LocationForegroundService is already running. Skipping duplicate launch.")
                    return
                }

                Log.d("FinCell_Boot", "Attempting to restart tracking service after boot for code: $code")

                val serviceIntent = Intent(context, LocationForegroundService::class.java).apply {
                    putExtra("code", code)
                }

                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(serviceIntent)
                    } else {
                        context.startService(serviceIntent)
                    }
                    Log.d("FinCell_Boot", "Foreground service started directly from BootReceiver")
                } catch (e: Exception) {
                    // Android 12+ (API 31+) background execution restriction fallback
                    Log.w("FinCell_Boot", "Direct foreground service start restricted by OS (${e.message}). Scheduling WorkManager fallback...")
                    scheduleWorkManagerFallback(context, code)
                }
            }
        } catch (e: Exception) {
            Log.e("FinCell_Boot", "BootReceiver top-level error: ${e.message}", e)
        }
    }

    private fun scheduleWorkManagerFallback(context: Context, code: String) {
        try {
            val inputData = Data.Builder()
                .putString("code", code)
                .build()

            val workRequest = OneTimeWorkRequestBuilder<BootServiceWorker>()
                .setInputData(inputData)
                .build()

            WorkManager.getInstance(context).enqueue(workRequest)
            Log.d("FinCell_Boot", "WorkManager fallback successfully enqueued for code: $code")
        } catch (e: Exception) {
            Log.e("FinCell_Boot", "Failed to enqueue WorkManager fallback: ${e.message}", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun isServiceRunning(context: Context, serviceClass: Class<*>): Boolean {
        try {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
            for (service in manager.getRunningServices(Integer.MAX_VALUE)) {
                if (serviceClass.name == service.service.className) {
                    return true
                }
            }
        } catch (e: Exception) {
            Log.e("FinCell_Boot", "Error checking if service is running: ${e.message}")
        }
        return false
    }
}