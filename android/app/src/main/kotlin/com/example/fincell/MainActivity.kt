package com.example.fincell

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private val CHANNEL = "fincell_service_channel"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        try {
            val prefs = getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
            val savedCode = prefs.getString("device_code", null)
            if (!savedCode.isNullOrEmpty()) {
                startTrackingService(savedCode)
            }
        } catch (_: Exception) {}

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                // ================= START SERVICE =================

                "startService" -> {

                    val code = call.argument<String>("code")

                    if (code.isNullOrEmpty()) {
                        result.error("INVALID_CODE", "Device code missing", null)
                        return@setMethodCallHandler
                    }

                    try {

                        val prefs = getSharedPreferences(
                            "fincell_prefs",
                            Context.MODE_PRIVATE
                        )

                        val isRunning = prefs.getBoolean("is_lost", false)

                        prefs.edit()
                            .putBoolean("is_lost", true)
                            .putString("device_code", code)
                            .apply()

                        startTrackingService(code)

                        result.success(if (isRunning) "Service Ensured" else "Service Started")

                    } catch (e: Exception) {

                        Log.e("FinCell", "Start service error", e)

                        result.error(
                            "SERVICE_ERROR",
                            e.message,
                            null
                        )
                    }
                }

                // ================= STOP SERVICE =================

                "stopService" -> {

                    try {

                        val prefs = getSharedPreferences(
                            "fincell_prefs",
                            Context.MODE_PRIVATE
                        )

                        prefs.edit()
                            .putBoolean("is_lost", false)
                            .remove("device_code")
                            .apply()

                        val intent = Intent(
                            this,
                            LocationForegroundService::class.java
                        )

                        stopService(intent)

                        result.success("Service Stopped")

                    } catch (e: Exception) {

                        Log.e("FinCell", "Stop service error", e)

                        result.error(
                            "STOP_ERROR",
                            e.message,
                            null
                        )
                    }
                }

                // ================= HIDE APP =================

                "hideApp" -> {

                    try {

                        AppVisibilityManager.hideApp(this)
                        result.success("App Hidden")

                    } catch (e: Exception) {

                        Log.e("FinCell", "Hide app error", e)

                        result.error("HIDE_ERROR", e.message, null)
                    }
                }

                // ================= SHOW APP =================

                "showApp" -> {

                    try {

                        AppVisibilityManager.showApp(this)
                        result.success("App Visible")

                    } catch (e: Exception) {

                        Log.e("FinCell", "Show app error", e)

                        result.error("SHOW_ERROR", e.message, null)
                    }
                }

                // ================= REQUEST BATTERY OPT =================

                "requestBatteryOptimization" -> {

                    requestIgnoreBatteryOptimizations()
                    result.success("Battery optimization intent opened")
                }

                // ================= LOCAL NOTIFICATION SOUND =================

                "playNotificationSound" -> {
                    try {
                        val notification = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_NOTIFICATION)
                        val ringtone = android.media.RingtoneManager.getRingtone(applicationContext, notification)
                        ringtone?.play()
                        result.success("Notification sound played")
                    } catch (e: Exception) {
                        Log.e("FinCell", "Error playing notification sound", e)
                        result.error("SOUND_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    // ================= START SERVICE HELPER =================

    private fun startTrackingService(code: String) {

        val intent = Intent(
            this,
            LocationForegroundService::class.java
        )

        intent.putExtra("code", code)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    // ================= BATTERY OPTIMIZATION =================

    private fun requestIgnoreBatteryOptimizations() {

        try {

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {

                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                val pkg = packageName

                if (!pm.isIgnoringBatteryOptimizations(pkg)) {

                    val intent = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                    )

                    intent.data = Uri.parse("package:$pkg")
                    startActivity(intent)
                }
            }

        } catch (e: Exception) {

            Log.e("FinCell", "Battery optimization error", e)
        }
    }
}
