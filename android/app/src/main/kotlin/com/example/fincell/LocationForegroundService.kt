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
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.SetOptions

class LocationForegroundService : LifecycleService() {

    private lateinit var fusedClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null
    private var commandListener: ListenerRegistration? = null
    private lateinit var wakeLock: PowerManager.WakeLock

    private val db = FirebaseFirestore.getInstance()

    private var cachedCode: String? = null
    private var cachedDeviceId: String? = null
    private var cachedOwnerUid: String? = null
    private var lastUpdateTime: Long = 0
    private var lastCacheTime: Long = 0 // 🔥 NEW

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

        val code = intent?.getStringExtra("code")?.uppercase()

        if (code.isNullOrEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, createNotification())

        if (!hasLocationPermission()) {
            stopSelf()
            return START_NOT_STICKY
        }

        startLocationUpdates(code)
        listenForCommands(code)

        return START_STICKY
    }

    // ================= LOCATION =================

    private fun startLocationUpdates(code: String) {
        locationCallback?.let {
            fusedClient.removeLocationUpdates(it)
        }

        if (cachedCode != code) {
            cachedCode = code
            cachedDeviceId = null
            cachedOwnerUid = null
            lastCacheTime = 0
            lastUpdateTime = 0
        }

        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            3000L
        )
            .setMinUpdateIntervalMillis(2000L)
            .setMinUpdateDistanceMeters(5f)
            .setWaitForAccurateLocation(true)
            .build()

        locationCallback = object : LocationCallback() {

            override fun onLocationResult(result: LocationResult) {

                val location = result.lastLocation ?: return

                val lat = location.latitude
                val lng = location.longitude
                val accuracy = location.accuracy
                val battery = getBatteryLevel()

                // 🔥 FILTER BAD GPS
                if (accuracy > 100) return

                // 🔥 THROTTLE
                val now = System.currentTimeMillis()
                if (now - lastUpdateTime < 3000) return
                lastUpdateTime = now

                // 🔥 CACHE WITH REFRESH (FIXED)
                if (cachedDeviceId == null || cachedOwnerUid == null || now - lastCacheTime > 60000) {

                    db.collection("device_codes")
                        .document(code)
                        .get()
                        .addOnSuccessListener { doc ->

                            cachedDeviceId = doc.getString("deviceId")
                            cachedOwnerUid = doc.getString("ownerUid")
                            cachedCode = code
                            lastCacheTime = System.currentTimeMillis()

                            if (cachedDeviceId == null || cachedOwnerUid == null) {
                                Log.e("TRACKING", "❌ Mapping missing")
                                return@addOnSuccessListener
                            }

                            writeLocation(code, lat, lng, accuracy, battery)
                        }
                        .addOnFailureListener {
                            Log.e("TRACKING", "❌ Mapping fetch failed: ${it.message}")
                        }

                } else {
                    writeLocation(code, lat, lng, accuracy, battery)
                }
            }
        }

        fusedClient.requestLocationUpdates(
            request,
            locationCallback!!,
            Looper.getMainLooper()
        )
    }

    // ================= FIRESTORE WRITE =================

    private fun writeLocation(
        code: String,
        lat: Double,
        lng: Double,
        accuracy: Float,
        battery: Int
    ) {

        val deviceId = cachedDeviceId
        val ownerUid = cachedOwnerUid

        if (deviceId == null || ownerUid == null) {
            Log.e("TRACKING", "❌ Cache missing, skip write")
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

        // 🔥 LIVE UPDATE
        db.collection("device_codes")
            .document(code)
            .set(updateData, SetOptions.merge())
            .addOnFailureListener {
                Log.e("TRACKING", "🔥 Live write failed: ${it.message}")
            }

        // 🔥 HISTORY SAVE
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
            .addOnFailureListener {
                Log.e("TRACKING", "🔥 History write failed: ${it.message}")
            }
    }

    // ================= COMMAND =================

    private fun listenForCommands(code: String) {
        commandListener?.remove()
        commandListener = db.collection("device_commands")
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
        } else 0 // 🔥 FIXED
    }

    // ================= WAKELOCK =================

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "FinCell::TrackingWakeLock"
        )
        wakeLock.acquire(10 * 60 * 1000L) // 🔥 SAFE TIMEOUT
    }

    // ================= PERMISSION =================

    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
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

        commandListener?.remove()
        commandListener = null

        if (::wakeLock.isInitialized && wakeLock.isHeld) {
            wakeLock.release()
        }

        stopAlarm()

        super.onDestroy()
    }
}
