package com.example.fincell

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat

object LocationReminderManager {

    const val NOTIFICATION_ID = 999
    const val CHANNEL_ID = "location_alert_channel"
    const val CHANNEL_NAME = "FinCell Location Alerts"
    const val ACTION_LOCATION_REMINDER = "com.example.fincell.CHECK_LOCATION_REMINDER"
    const val REMINDER_ALARM_REQUEST_CODE = 998
    const val REMINDER_INTERVAL_MINUTES = 30L
    const val REMINDER_INTERVAL_MS = REMINDER_INTERVAL_MINUTES * 60 * 1000L

    /**
     * Determines whether the device's system Location Service / GPS is globally enabled.
     * Accurately distinguishes system Location Service state from app-specific permission denials.
     */
    fun isLocationServiceEnabled(context: Context): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm.isLocationEnabled
        } else {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    /**
     * Evaluates the current system Location Service state:
     * - If Location is OFF: displays the "Turn On Location" notification and ensures the 30-min reminder is scheduled.
     * - If Location is ON: immediately cancels the notification and stops all reminder scheduling.
     */
    fun checkAndNotify(context: Context) {
        try {
            val locationEnabled = isLocationServiceEnabled(context)
            Log.d("LocationReminder", "Checking system Location Service state: enabled=$locationEnabled")

            if (!locationEnabled) {
                showTurnOnLocationNotification(context)
                schedulePeriodicReminder(context)
            } else {
                cancelReminder(context)
            }
        } catch (e: Exception) {
            Log.e("LocationReminder", "Error in checkAndNotify: ${e.message}", e)
        }
    }

    /**
     * Posts the "Turn On Location" notification.
     * Tapping the notification directly launches Android Location Settings.
     */
    fun showTurnOnLocationNotification(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            createNotificationChannel(nm)

            val settingsIntent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }

            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                settingsIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val title = "Turn On Location"
            val body = "Location service is turned off. Please turn on Location to keep FinCell tracking active."

            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .addAction(
                    android.R.drawable.ic_menu_mylocation,
                    "Turn On Location",
                    pendingIntent
                )

            nm.notify(NOTIFICATION_ID, builder.build())
            Log.d("LocationReminder", "Posted 'Turn On Location' reminder notification (ID $NOTIFICATION_ID)")
        } catch (e: Exception) {
            Log.e("LocationReminder", "Failed to show reminder notification: ${e.message}", e)
        }
    }

    /**
     * Schedules the next periodic reminder alarm for approx 30 minutes.
     * Checks if an alarm is already scheduled to avoid duplicate schedulers.
     */
    fun schedulePeriodicReminder(context: Context, forceReschedule: Boolean = false) {
        try {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return

            val intent = Intent(context, LocationReminderReceiver::class.java).apply {
                action = ACTION_LOCATION_REMINDER
            }

            if (!forceReschedule) {
                val existingPendingIntent = PendingIntent.getBroadcast(
                    context,
                    REMINDER_ALARM_REQUEST_CODE,
                    intent,
                    PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
                )
                if (existingPendingIntent != null) {
                    Log.d("LocationReminder", "Periodic reminder alarm is already active. Skipping duplicate schedule.")
                    return
                }
            }

            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REMINDER_ALARM_REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val triggerAtMillis = System.currentTimeMillis() + REMINDER_INTERVAL_MS

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            } else {
                alarmManager.set(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            }
            Log.d("LocationReminder", "Scheduled next 30-minute reminder for $triggerAtMillis")
        } catch (e: Exception) {
            Log.e("LocationReminder", "Error scheduling reminder alarm: ${e.message}", e)
        }
    }

    /**
     * Cancels any active "Turn On Location" notifications and cancels scheduled reminder alarms.
     */
    fun cancelReminder(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.cancel(NOTIFICATION_ID)

            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            val intent = Intent(context, LocationReminderReceiver::class.java).apply {
                action = ACTION_LOCATION_REMINDER
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REMINDER_ALARM_REQUEST_CODE,
                intent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
            )
            if (pendingIntent != null && alarmManager != null) {
                alarmManager.cancel(pendingIntent)
                pendingIntent.cancel()
            }
            Log.d("LocationReminder", "Cancelled Location Reminder notification and scheduled alarms.")
        } catch (e: Exception) {
            Log.e("LocationReminder", "Error cancelling reminder: ${e.message}", e)
        }
    }

    private fun createNotificationChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifies user when GPS/Location services are turned off"
                enableVibration(true)
            }
            nm.createNotificationChannel(channel)
        }
    }
}
