package com.example.fincell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager

class NetworkReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {

        val prefs = context.getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
        val isLost = prefs.getBoolean("is_lost", false)

        if (!isLost) return

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetworkInfo

        if (network != null && network.isConnected) {

            val serviceIntent = Intent(context, LocationForegroundService::class.java)
            context.startForegroundService(serviceIntent)
        }
    }
}