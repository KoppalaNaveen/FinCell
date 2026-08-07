package com.example.fincell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.os.Build

class NetworkReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {

        val prefs = context.getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
        val code = prefs.getString("device_code", null)

        if (code.isNullOrEmpty()) return

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetworkInfo

        if (network != null && network.isConnected) {

            val serviceIntent = Intent(context, LocationForegroundService::class.java).apply {
                putExtra("code", code)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }
    }
}
