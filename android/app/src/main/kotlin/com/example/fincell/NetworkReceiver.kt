package com.example.fincell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.os.Build

class NetworkReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {

        val prefs = context.getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
        val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        var code = prefs.getString("device_code", null)
        if (code.isNullOrEmpty()) {
            val flutterCode = flutterPrefs.getString("flutter.uniqueCode", null)
            if (!flutterCode.isNullOrEmpty()) {
                code = flutterCode.replace("\"", "").trim()
            }
        }

        if (code.isNullOrEmpty()) return

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        @Suppress("DEPRECATION")
        val network = cm.activeNetworkInfo

        @Suppress("DEPRECATION")
        if (network != null && network.isConnected) {
            try {
                val serviceIntent = Intent(context, LocationForegroundService::class.java).apply {
                    putExtra("code", code)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (e: Exception) {
                android.util.Log.w("FinCell_Net", "Failed to start service on network change: ${e.message}")
            }
        }
    }
}
