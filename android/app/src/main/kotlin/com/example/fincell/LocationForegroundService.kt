package com.example.fincell

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.media.MediaPlayer
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import com.google.android.gms.location.*
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions

class LocationForegroundService : LifecycleService() {

    private lateinit var fusedClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null
    private lateinit var wakeLock: PowerManager.WakeLock

    private val db = FirebaseFirestore.getInstance()
    private val auth = FirebaseAuth.getInstance()

    private var mediaPlayer: MediaPlayer? = null

    private val CHANNEL_ID = "lost_tracking_channel"
    private val NOTIFICATION_ID = 1

    override fun onCreate() {
        super.onCreate()

        fusedClient = LocationServices.getFusedLocationProviderClient(this)

        acquireWakeLock()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {

        val rawCode = intent?.getStringExtra("code")
        val code = rawCode?.uppercase()

        Log.d("TRACKING", "🚀 Service started with code: $code")

        if (code.isNullOrEmpty()) {
            Log.e("TRACKING", "❌ Code NULL → stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, createNotification())

        if (!hasLocationPermission()) {
            Log.e("TRACKING", "❌ No location permission")
            stopSelf()
            return START_NOT_STICKY
        }

        if (!isGpsEnabled()) {
            Log.e("TRACKING", "⚠️ GPS is OFF")
        }

        startLocationUpdates(code)
        listenForCommands(code)

        return START_STICKY
    }

    // ================= GPS =================

    private fun isGpsEnabled(): Boolean {
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return manager.isProviderEnabled(LocationManager.GPS_PROVIDER)
    }

    // ================= WAKELOCK =================

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "FinCell::TrackingWakeLock"
        )
        wakeLock.acquire()
    }

    // ================= PERMISSION =================

    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    // ================= LOCATION =================

    private fun startLocationUpdates(code: String) {

        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            3000L
        )
            .setMinUpdateIntervalMillis(2000L)
            .setMinUpdateDistanceMeters(5f)
            .build()

        locationCallback = object : LocationCallback() {

            override fun onLocationResult(result: LocationResult) {

                val location = result.lastLocation ?: return

                val lat = location.latitude
                val lng = location.longitude
                val accuracy = location.accuracy
                val battery = getBatteryLevel()

                Log.d("TRACKING", "📍 Lat:$lat Lng:$lng Acc:$accuracy Battery:$battery")

                // 🔥 Accept real-world GPS (don't over-filter)
                if (accuracy > 100) {
                    Log.d("TRACKING", "⚠️ Ignored bad accuracy: $accuracy")
                    return
                }

                val updateData = hashMapOf<String, Any>(
                    "lastLocation" to hashMapOf(
                        "lat" to lat,
                        "lng" to lng,
                        "accuracy" to accuracy,
                        "battery" to battery,
                        "updatedAt" to Timestamp.now()
                    ),
                    "updatedAt" to Timestamp.now()
                )

                // 🔥 STEP 1: Get deviceId from device_codes
                db.collection("device_codes")
                    .document(code)
                    .get()
                    .addOnSuccessListener { doc ->

                        val deviceId = doc.getString("deviceId")
                        val ownerUid = doc.getString("ownerUid")

                        if (deviceId == null || ownerUid == null) {
                            Log.e("TRACKING", "❌ deviceId missing")
                            return@addOnSuccessListener
                        }

                        // 🔥 STEP 2: Update LIVE location
                        db.collection("device_codes")
                            .document(code)
                            .set(updateData, SetOptions.merge())

                        // 🔥 STEP 3: Save HISTORY (correct path)
                        db.collection("users")
                            .document(ownerUid)
                            .collection("devices")
                            .document(deviceId)
                            .collection("locations")
                            .add(
                                hashMapOf(
                                    "lat" to lat,
                                    "lng" to lng,
                                    "accuracy" to accuracy,
                                    "battery" to battery,
                                    "timestamp" to Timestamp.now()
                                )
                            )

                        Log.d("TRACKING", "✅ Location + History stored")
                    }
                    .addOnFailureListener {
                        Log.e("TRACKING", "❌ deviceId fetch failed: ${it.message}")
                    }
            }
        }

        fusedClient.requestLocationUpdates(
            request,
            locationCallback!!,
            Looper.getMainLooper()
        )
    }

    // ================= COMMAND =================

    private fun listenForCommands(code: String) {

        db.collection("device_commands")
            .document(code)
            .addSnapshotListener { snapshot, _ ->

                val command = snapshot?.getString("command") ?: return@addSnapshotListener

                when (command) {
                    "alarm" -> startAlarm()
                    "stop_alarm" -> stopAlarm()
                }
            }
    }

    // ================= ALARM =================

    private fun startAlarm() {
        if (mediaPlayer == null) {
            mediaPlayer = MediaPlayer.create(
                this,
                android.provider.Settings.System.DEFAULT_ALARM_ALERT_URI
            )
            mediaPlayer?.isLooping = true
            mediaPlayer?.start()
        }
    }

    private fun stopAlarm() {
        mediaPlayer?.stop()
        mediaPlayer?.release()
        mediaPlayer = null
    }

    // ================= BATTERY =================

    private fun getBatteryLevel(): Int {

        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))

        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1

        return if (level >= 0 && scale > 0) {
            level * 100 / scale
        } else -1
    }

    // ================= NOTIFICATION =================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Tracking Service",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("FinCell Tracking Active")
            .setContentText("Tracking device in background")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
    }

    // ================= DESTROY =================

    override fun onDestroy() {

        locationCallback?.let {
            fusedClient.removeLocationUpdates(it)
        }

        if (::wakeLock.isInitialized && wakeLock.isHeld) {
            wakeLock.release()
        }

        stopAlarm()

        Log.d("TRACKING", "🛑 Service destroyed")

        super.onDestroy()
    }
}