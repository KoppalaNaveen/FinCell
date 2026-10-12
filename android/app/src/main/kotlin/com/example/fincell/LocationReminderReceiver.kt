package com.example.fincell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.util.Log

class LocationReminderReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        Log.d("LocationReminderReceiver", "Received broadcast action: $action")

        when (action) {
            LocationReminderManager.ACTION_LOCATION_REMINDER -> {
                val isEnabled = LocationReminderManager.isLocationServiceEnabled(context)
                if (!isEnabled) {
                    LocationReminderManager.showTurnOnLocationNotification(context)
                    // Re-schedule for the next 30-minute interval while location remains OFF
                    LocationReminderManager.schedulePeriodicReminder(context, forceReschedule = true)
                } else {
                    LocationReminderManager.cancelReminder(context)
                }
            }
            LocationManager.PROVIDERS_CHANGED_ACTION -> {
                // Instantly react to user toggling Location ON/OFF in system settings or quick settings
                LocationReminderManager.checkAndNotify(context)
            }
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED -> {
                LocationReminderManager.checkAndNotify(context)
            }
        }
    }
}
