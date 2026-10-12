package com.example.fincell

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

class BootServiceWorker(
    private val context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    override fun doWork(): Result {
        return try {
            val code = inputData.getString("code")
            if (code.isNullOrEmpty()) {
                Log.d("BootServiceWorker", "No device code provided for WorkManager task")
                return Result.failure()
            }

            Log.d("BootServiceWorker", "WorkManager executing service launch for code: $code")

            val serviceIntent = Intent(context, LocationForegroundService::class.java).apply {
                putExtra("code", code)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }

            Result.success()
        } catch (e: Exception) {
            Log.e("BootServiceWorker", "Error restoring service via WorkManager: ${e.message}", e)
            Result.retry()
        }
    }
}
