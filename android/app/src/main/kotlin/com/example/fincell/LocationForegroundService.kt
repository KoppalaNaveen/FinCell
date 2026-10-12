package com.example.fincell

import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.*
import android.location.Location
import android.location.LocationManager
import android.media.*
import android.net.*
import android.net.wifi.WifiManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.os.*
import android.provider.Settings
import android.telephony.*
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import com.google.android.gms.location.*
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.SetOptions
import com.google.firebase.storage.FirebaseStorage
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import org.json.JSONObject
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import android.bluetooth.*
import android.bluetooth.le.*
import java.util.UUID

class LocationForegroundService : LifecycleService(), SensorEventListener {

    private lateinit var fusedClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null
    private var commandListener: ListenerRegistration? = null
    private lateinit var wakeLock: PowerManager.WakeLock

    private val db = FirebaseFirestore.getInstance()

    private var cachedCode: String? = null
    private var cachedDeviceId: String? = null
    private var cachedOwnerUid: String? = null
    private var lastUpdateTime: Long = 0
    private var lastCacheTime: Long = 0
    private var lastLocation: Location? = null
    private var serviceStartTime: Long = 0

    // Battery optimization & dynamic mode state
    private var isLostModeActive: Boolean = false
    private var lastWrittenRiskScore: Int = -1
    private var lastWrittenTheftStatus: String = ""
    private var lastRiskDbWriteTime: Long = 0L
    private var lastFirestoreWriteTime: Long = 0L

    // Kalman filter state for GPS smoothing
    private var kalmanLat: Double = 0.0
    private var kalmanLng: Double = 0.0
    private var kalmanVariance: Double = Double.MAX_VALUE
    private var kalmanInitialized: Boolean = false

    // Native offline location queue
    private var offlineDb: android.database.sqlite.SQLiteDatabase? = null

    // 🔥 DIRECT LOCAL OFFLINE TRACE RESPONDER
    private var directUdpSocket: DatagramSocket? = null
    private var directSocketThread: Thread? = null
    private var gattServer: BluetoothGattServer? = null
    private var bleAdvertiser: BluetoothLeAdvertiser? = null
    private var bleAdvertiseCallback: AdvertiseCallback? = null

    private var mediaPlayer: MediaPlayer? = null
    private var activeRingtone: Ringtone? = null
    private var toneGenerator: ToneGenerator? = null
    private var sirenTimer: java.util.Timer? = null
    private var alarmTimeoutHandler: Handler? = null
    private var connectivityCallback: ConnectivityManager.NetworkCallback? = null

    // 🔥 THEFT DETECTION & SCANNERS
    private lateinit var sensorManager: SensorManager
    private var accelerometer: Sensor? = null
    private var proximitySensor: Sensor? = null

    private var lastProximityValue: Float = -1f
    private var isScreenLocked: Boolean = false
    private var isChargerDisconnected: Boolean = false
    private var isSimRemoved: Boolean = false
    private var isPocketRemovalDetected: Boolean = false
    private var lastTheftTriggerTime: Long = 0

    private var silentCameraManager: SilentCameraManager? = null
    private var cameraTimerHandler: Handler? = null
    private var mediaRecorder: MediaRecorder? = null
    private var audioFile: File? = null

    companion object {
        const val LOCATION_REMINDER_INTERVAL_MINUTES = 30L
        const val DEVICE_FIRESTORE_UPDATE_INTERVAL_MINUTES = 6L
        const val ACTION_LOCATION_REMINDER = "com.example.fincell.CHECK_LOCATION_REMINDER"
        const val DIRECT_TRACE_PORT = 48888
        val FINCELL_SERVICE_UUID: UUID = UUID.fromString("0000FC01-0000-1000-8000-00805F9B34FB")
        val FINCELL_TELEMETRY_CHAR_UUID: UUID = UUID.fromString("0000FC02-0000-1000-8000-00805F9B34FB")
        private const val HMAC_SECRET_KEY = "FinCell_HMAC_Secret_Key_v1_Prod"
    }

    private val LOCATION_REMINDER_INTERVAL_MS = LOCATION_REMINDER_INTERVAL_MINUTES * 60 * 1000L
    private val DEVICE_FIRESTORE_UPDATE_INTERVAL_MS = DEVICE_FIRESTORE_UPDATE_INTERVAL_MINUTES * 60 * 1000L
    private val REMINDER_ALARM_REQUEST_CODE = 998

    private var currentRiskScore: Int = 0
    private var currentTheftStatus: String = "Normal"
    private var periodicUpdateHandler: Handler? = null
    private var periodicUpdateRunnable: Runnable? = null

    private val CHANNEL_ID = "lost_tracking_channel"
    private val NOTIFICATION_ID = 1

    private val LOCATION_OFF_NOTIFICATION_ID = 999
    private val ALERT_CHANNEL_ID = "location_alert_channel"

    private val systemReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    isScreenLocked = true
                    evaluateTheftRisk("Screen Locked / Turned Off")
                }
                Intent.ACTION_SCREEN_ON -> {
                    isScreenLocked = false
                }
                Intent.ACTION_POWER_DISCONNECTED -> {
                    isChargerDisconnected = true
                    evaluateTheftRisk("Charger Unplugged")
                }
                "android.intent.action.SIM_STATE_CHANGED" -> {
                    val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
                    isSimRemoved = (tm.simState == TelephonyManager.SIM_STATE_ABSENT)
                    if (isSimRemoved) {
                        evaluateTheftRisk("SIM Removed / Changed")
                    }
                }
                LocationManager.PROVIDERS_CHANGED_ACTION -> {
                    checkAndNotifyLocationState()
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()

        fusedClient = LocationServices.getFusedLocationProviderClient(this)
        silentCameraManager = SilentCameraManager(this, this)

        acquireWakeLock()
        createNotificationChannel()
        registerNetworkCallback()
        initSensorsAndReceivers()
        checkAndNotifyLocationState()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)

        try {
            startForeground(NOTIFICATION_ID, createNotification())
        } catch (_: Exception) {}

        val action = intent?.action
        if (action == ACTION_LOCATION_REMINDER) {
            checkAndNotifyLocationState()
            return START_STICKY
        }
        if (action == "com.example.fincell.START_ALARM") {
            val prefs = getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
            val savedCode = prefs.getString("device_code", null)?.uppercase()
            val targetCode = intent?.getStringExtra("code")?.uppercase() ?: cachedCode ?: savedCode ?: ""
            startAlarm(targetCode)
            return START_STICKY
        }
        if (action == "com.example.fincell.STOP_ALARM") {
            val prefs = getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
            val savedCode = prefs.getString("device_code", null)?.uppercase()
            val targetCode = intent?.getStringExtra("code")?.uppercase() ?: cachedCode ?: savedCode ?: ""
            stopAlarm(targetCode)
            return START_STICKY
        }

        var code = intent?.getStringExtra("code")?.uppercase()

        if (code.isNullOrEmpty()) {
            val prefs = getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
            code = prefs.getString("device_code", null)?.uppercase()
        }

        if (code.isNullOrEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }

        cachedCode = code

        checkAndNotifyLocationState()

        if (!hasLocationPermission()) {
            stopSelf()
            return START_NOT_STICKY
        }

        startLocationUpdates(code)
        startPeriodicFirestoreUpdates(code)
        listenForCommands(code)
        startCameraCaptureTimer(code)
        startDirectLocalTraceResponder(code)

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d("FinCell", "App closed/swiped away. Restarting service to keep running in background...")

        val prefs = getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
        val code = prefs.getString("device_code", null)

        if (!code.isNullOrEmpty()) {
            val restartIntent = Intent(applicationContext, LocationForegroundService::class.java).apply {
                putExtra("code", code)
            }
            val pendingIntent = PendingIntent.getService(
                applicationContext,
                1,
                restartIntent,
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
            )
            val alarmManager = applicationContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.set(
                AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + 1000,
                pendingIntent
            )
        }
    }

    private fun checkAndNotifyLocationState() {
        LocationReminderManager.checkAndNotify(this)
    }

    private fun scheduleLocationReminderAlarm() {
        LocationReminderManager.schedulePeriodicReminder(this)
    }

    private fun cancelLocationReminderAlarm() {
        LocationReminderManager.cancelReminder(this)
    }

    private fun createLocationAlertChannel(nm: NotificationManager) {
        // Handled centrally in LocationReminderManager
    }

    // ================= SENSORS & SYSTEM EVENT LISTENERS =================

    private fun initSensorsAndReceivers() {
        try {
            sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
            accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            proximitySensor = sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY)

            accelerometer?.let {
                sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
            }
            proximitySensor?.let {
                sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
            }

            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
                addAction("android.intent.action.SIM_STATE_CHANGED")
                addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
            }
            registerReceiver(systemReceiver, filter)
        } catch (e: Exception) {
            Log.e("THEFT_ENGINE", "Error initializing sensors: ${e.message}")
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event == null) return

        when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> {
                val x = event.values[0]
                val y = event.values[1]
                val z = event.values[2]
                val mag = Math.sqrt((x * x + y * y + z * z).toDouble())

                // Sudden Acceleration threshold (> 22 m/s²)
                if (mag > 22.0 && (System.currentTimeMillis() - lastTheftTriggerTime > 10000)) {
                    evaluateTheftRisk("Sudden Acceleration Spike (${mag.toInt()} m/s²)")
                }
            }
            Sensor.TYPE_PROXIMITY -> {
                val dist = event.values[0]
                if (lastProximityValue >= 0 && lastProximityValue < 1.0f && dist >= 1.0f) {
                    isPocketRemovalDetected = true
                    evaluateTheftRisk("Phone Removed from Pocket")
                }
                lastProximityValue = dist
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    // ================= RULE-BASED THEFT RISK ENGINE =================

    private fun evaluateTheftRisk(triggerReason: String) {
        val code = cachedCode ?: return

        var score = 0
        val factors = ArrayList<String>()

        // Rule weights:
        // SIM Removed = 30
        if (isSimRemoved) {
            score += 30
            factors.add("SIM Removed")
        }

        // GPS Disabled = 20
        if (!isGpsEnabled()) {
            score += 20
            factors.add("GPS Disabled")
        }

        // Airplane Mode = 15
        val isAirplaneMode = Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0
        if (isAirplaneMode) {
            score += 15
            factors.add("Airplane Mode Enabled")
        }

        // Fast Movement = 15
        val speed = lastLocation?.speed?.toDouble() ?: 0.0
        if (speed > 4.5) { // Running / vehicle speed
            score += 15
            factors.add("Fast Movement (${(speed * 3.6).toInt()} km/h)")
        }

        // Internet Lost = 10
        if (!isNetworkAvailable()) {
            score += 10
            factors.add("Internet Disconnected")
        }

        // Pocket Removal = 10
        if (isPocketRemovalDetected) {
            score += 10
            factors.add("Phone Removed from Pocket")
        }

        // Charger Unplugged = 5
        if (isChargerDisconnected) {
            score += 5
            factors.add("Charger Unplugged")
        }

        // Screen Locked / Off = 5
        if (isScreenLocked) {
            score += 5
            factors.add("Screen Locked / Turned Off")
        }

        val riskScore = score.coerceAtMost(100)
        currentRiskScore = riskScore
        currentTheftStatus = if (riskScore >= 50) "Possible Theft Detected" else "Normal"

        val nowTime = System.currentTimeMillis()
        if (riskScore != lastWrittenRiskScore || currentTheftStatus != lastWrittenTheftStatus || (nowTime - lastRiskDbWriteTime > 60000L)) {
            lastWrittenRiskScore = riskScore
            lastWrittenTheftStatus = currentTheftStatus
            lastRiskDbWriteTime = nowTime

            val riskData = hashMapOf<String, Any>(
                "riskScore" to riskScore,
                "riskFactors" to factors,
                "theftStatus" to currentTheftStatus,
                "lastRiskUpdate" to Timestamp.now()
            )
            db.collection("device_codes")
                .document(code)
                .set(riskData, SetOptions.merge())
        }

        // 🔥 AUTOMATIC THEFT ACTION WHEN RISK SCORE >= 50%
        if (riskScore >= 50 && System.currentTimeMillis() - lastTheftTriggerTime > 30000) {
            lastTheftTriggerTime = System.currentTimeMillis()

            // 1. Enable Lost Mode in Firestore
            val lostData = hashMapOf<String, Any>(
                "isLost" to true,
                "traceRequestedAt" to Timestamp.now()
            )
            db.collection("device_codes")
                .document(code)
                .set(lostData, SetOptions.merge())

            // 2. Silent Camera Photo Capture
            silentCameraManager?.captureFrontCamera(
                deviceCode = code,
                reason = "High Theft Risk ($riskScore%): $triggerReason",
                lat = lastLocation?.latitude,
                lng = lastLocation?.longitude,
                battery = getBatteryLevel()
            )

            // 3. Environment Scan
            scanWifiEnvironment(code)
            scanBluetoothEnvironment(code)
            scanCellTowerInfo(code)

            // 4. Log Security Timeline Event
            logTimelineEvent(
                code = code,
                eventType = "THEFT_WARNING",
                title = "Possible Theft Detected ($riskScore%)",
                description = "Triggered by: $triggerReason. Risk factors: ${factors.joinToString(", ")}"
            )
        }
    }

    // ================= LOCATION UPDATES =================

    private var codeStatusListener: ListenerRegistration? = null

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
            lastLocation = null
        }

        // Native snapshot listener for remote lost mode & sound triggers
        codeStatusListener?.remove()
        codeStatusListener = db.collection("device_codes")
            .document(code)
            .addSnapshotListener { snapshot, error ->
                if (error != null || snapshot == null || !snapshot.exists()) return@addSnapshotListener
                val owner = snapshot.getString("ownerUid")
                val device = snapshot.getString("deviceId")
                val isLost = snapshot.getBoolean("isLost") ?: false
                val traceRequestedAt = snapshot.getTimestamp("traceRequestedAt")
                val playSound = snapshot.getBoolean("playSound") ?: false

                if (!owner.isNullOrEmpty()) cachedOwnerUid = owner
                if (!device.isNullOrEmpty()) cachedDeviceId = device

                val wasLostMode = isLostModeActive
                isLostModeActive = isLost || (traceRequestedAt != null)

                if (isLostModeActive != wasLostMode) {
                    reconfigureLocationUpdates(code)
                }

                if (isLost || traceRequestedAt != null) {
                    fetchAndPushImmediateLocation(code)
                }

                if (playSound) {
                    startAlarm(code)
                } else if (snapshot.contains("playSound") && !playSound) {
                    stopAlarm(code)
                }
            }

        serviceStartTime = System.currentTimeMillis()

        val request = if (isLostModeActive) {
            LocationRequest.Builder(
                Priority.PRIORITY_HIGH_ACCURACY,
                2000L
            )
                .setMinUpdateIntervalMillis(1000L)
                .setMinUpdateDistanceMeters(0f)
                .setWaitForAccurateLocation(true)
                .build()
        } else {
            LocationRequest.Builder(
                Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                15000L
            )
                .setMinUpdateIntervalMillis(5000L)
                .setMinUpdateDistanceMeters(3f)
                .setWaitForAccurateLocation(false)
                .build()
        }

        locationCallback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val location = result.lastLocation ?: return

                val rawLat = location.latitude
                val rawLng = location.longitude
                val accuracy = location.accuracy
                val battery = getBatteryLevel()
                val speed = location.speed.toDouble()
                val heading = location.bearing.toDouble()

                // Adaptive accuracy threshold: 250m for first 10s, then tighten to 50m
                val elapsedSinceStart = System.currentTimeMillis() - serviceStartTime
                val maxAccuracy = when {
                    elapsedSinceStart < 10000L -> 250f  // First 10s: accept coarse fixes
                    elapsedSinceStart < 30000L -> 100f  // 10-30s: moderate threshold
                    else -> 50f                          // After 30s: only accurate fixes
                }
                if (accuracy > maxAccuracy) return

                // Apply Kalman filter for GPS smoothing
                val filtered = applyKalmanFilter(rawLat, rawLng, accuracy.toDouble())
                val lat = filtered.first
                val lng = filtered.second

                val now = System.currentTimeMillis()
                val prev = lastLocation
                var hasSignificantMovement = true
                if (prev != null) {
                    val distanceMoved = prev.distanceTo(location)
                    if (distanceMoved < 0.5f && (now - lastUpdateTime < 3000)) {
                        return
                    }
                    if (distanceMoved < 2.0f && speed < 0.5) {
                        hasSignificantMovement = false
                    }
                }

                if (now - lastUpdateTime < 1000) return
                lastUpdateTime = now
                lastLocation = location

                // Energy Optimization: Write immediately if in Lost Mode or has moved > 2m,
                // otherwise throttle stationary writes to at most once per 30 seconds.
                val shouldWriteDb = isLostModeActive || hasSignificantMovement || (now - lastFirestoreWriteTime >= 30000L)

                if (shouldWriteDb) {
                    lastFirestoreWriteTime = now
                    if (isNetworkAvailable()) {
                        writeLocation(code, lat, lng, accuracy, battery, speed, heading)
                        flushOfflineLocationQueue(code)
                    } else {
                        queueOfflineLocation(code, lat, lng, accuracy, battery, speed, heading)
                    }
                }

                // Periodic Theft Risk Evaluation
                evaluateTheftRisk("Location Update")
            }
        }

        fusedClient.requestLocationUpdates(
            request,
            locationCallback!!,
            Looper.getMainLooper()
        )
    }

    private fun reconfigureLocationUpdates(code: String) {
        if (!hasLocationPermission() || locationCallback == null) return

        try {
            fusedClient.removeLocationUpdates(locationCallback!!)

            val request = if (isLostModeActive) {
                LocationRequest.Builder(
                    Priority.PRIORITY_HIGH_ACCURACY,
                    2000L
                )
                    .setMinUpdateIntervalMillis(1000L)
                    .setMinUpdateDistanceMeters(0f)
                    .setWaitForAccurateLocation(true)
                    .build()
            } else {
                LocationRequest.Builder(
                    Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                    15000L
                )
                    .setMinUpdateIntervalMillis(5000L)
                    .setMinUpdateDistanceMeters(3f)
                    .setWaitForAccurateLocation(false)
                    .build()
            }

            fusedClient.requestLocationUpdates(
                request,
                locationCallback!!,
                Looper.getMainLooper()
            )
            Log.d("FinCell", "Reconfigured location updates. isLostModeActive=$isLostModeActive")
        } catch (e: Exception) {
            Log.w("FinCell", "Error reconfiguring location updates: ${e.message}")
        }
    }

    // ================= KALMAN FILTER FOR GPS SMOOTHING =================

    private fun applyKalmanFilter(lat: Double, lng: Double, accuracy: Double): Pair<Double, Double> {
        // Measurement noise (variance from GPS accuracy in meters, converted to degrees approx)
        val measurementVariance = (accuracy * accuracy) / (111000.0 * 111000.0) // ~111km per degree

        if (!kalmanInitialized) {
            kalmanLat = lat
            kalmanLng = lng
            kalmanVariance = measurementVariance
            kalmanInitialized = true
            return Pair(lat, lng)
        }

        // Process noise: how much we expect the position to change between updates (~walking speed)
        val processNoise = 0.000001 // ~0.1m drift per update cycle

        // Predict step
        val predictedVariance = kalmanVariance + processNoise

        // Update step (Kalman gain)
        val kalmanGain = predictedVariance / (predictedVariance + measurementVariance)

        // Update state
        kalmanLat = kalmanLat + kalmanGain * (lat - kalmanLat)
        kalmanLng = kalmanLng + kalmanGain * (lng - kalmanLng)
        kalmanVariance = (1.0 - kalmanGain) * predictedVariance

        return Pair(kalmanLat, kalmanLng)
    }

    // ================= NATIVE OFFLINE LOCATION QUEUE =================

    private fun getOrCreateOfflineDb(): android.database.sqlite.SQLiteDatabase {
        if (offlineDb == null || !offlineDb!!.isOpen) {
            offlineDb = android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(
                File(filesDir, "fincell_offline_queue.db"), null
            )
            offlineDb?.execSQL("""
                CREATE TABLE IF NOT EXISTS offline_locations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    code TEXT NOT NULL,
                    lat REAL NOT NULL,
                    lng REAL NOT NULL,
                    accuracy REAL NOT NULL,
                    battery INTEGER NOT NULL,
                    speed REAL NOT NULL,
                    heading REAL NOT NULL,
                    timestamp INTEGER NOT NULL
                )
            """.trimIndent())
        }
        return offlineDb!!
    }

    private fun queueOfflineLocation(code: String, lat: Double, lng: Double, accuracy: Float, battery: Int, speed: Double, heading: Double) {
        try {
            val db = getOrCreateOfflineDb()
            val values = android.content.ContentValues().apply {
                put("code", code)
                put("lat", lat)
                put("lng", lng)
                put("accuracy", accuracy.toDouble())
                put("battery", battery)
                put("speed", speed)
                put("heading", heading)
                put("timestamp", System.currentTimeMillis())
            }
            db.insert("offline_locations", null, values)

            // Enforce 5000 entry limit
            db.execSQL("DELETE FROM offline_locations WHERE id NOT IN (SELECT id FROM offline_locations ORDER BY id DESC LIMIT 5000)")
            Log.d("OFFLINE_QUEUE", "Location queued offline for code=$code (lat=$lat, lng=$lng, acc=$accuracy)")
        } catch (e: Exception) {
            Log.w("OFFLINE_QUEUE", "Failed to queue offline location: ${e.message}")
        }
    }

    private fun flushOfflineLocationQueue(code: String) {
        try {
            val localDb = getOrCreateOfflineDb()
            val cursor = localDb.rawQuery("SELECT * FROM offline_locations WHERE code = ? ORDER BY timestamp ASC LIMIT 100", arrayOf(code))
            val idsToDelete = mutableListOf<Long>()

            while (cursor.moveToNext()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow("id"))
                val lat = cursor.getDouble(cursor.getColumnIndexOrThrow("lat"))
                val lng = cursor.getDouble(cursor.getColumnIndexOrThrow("lng"))
                val accuracy = cursor.getDouble(cursor.getColumnIndexOrThrow("accuracy")).toFloat()
                val battery = cursor.getInt(cursor.getColumnIndexOrThrow("battery"))
                val speed = cursor.getDouble(cursor.getColumnIndexOrThrow("speed"))
                val heading = cursor.getDouble(cursor.getColumnIndexOrThrow("heading"))

                writeLocation(code, lat, lng, accuracy, battery, speed, heading)
                idsToDelete.add(id)
            }
            cursor.close()

            if (idsToDelete.isNotEmpty()) {
                val idList = idsToDelete.joinToString(",")
                localDb.execSQL("DELETE FROM offline_locations WHERE id IN ($idList)")
                Log.d("OFFLINE_QUEUE", "Flushed ${idsToDelete.size} queued locations to Firestore for code=$code")
            }
        } catch (e: Exception) {
            Log.w("OFFLINE_QUEUE", "Failed to flush offline queue: ${e.message}")
        }
    }

    private fun fetchAndPushImmediateLocation(code: String) {
        try {
            if (!hasLocationPermission()) return

            fusedClient.getCurrentLocation(
                Priority.PRIORITY_HIGH_ACCURACY,
                null
            ).addOnSuccessListener { location ->
                if (location != null) {
                    val lat = location.latitude
                    val lng = location.longitude
                    val accuracy = location.accuracy
                    val battery = getBatteryLevel()
                    val speed = location.speed.toDouble()
                    val heading = location.bearing.toDouble()
                    lastLocation = location

                    writeLocation(code, lat, lng, accuracy, battery, speed, heading)
                } else {
                    lastLocation?.let { loc ->
                        writeLocation(code, loc.latitude, loc.longitude, loc.accuracy, getBatteryLevel(), loc.speed.toDouble(), loc.bearing.toDouble())
                    }
                }
                val now = Timestamp.now()
                val cmdUpdate = hashMapOf<String, Any>(
                    "status" to "completed",
                    "completedAt" to now
                )
                db.collection("device_commands")
                    .document(code)
                    .set(cmdUpdate, SetOptions.merge())
            }.addOnFailureListener { e ->
                markCommandFailed(code, "Location fetch failed: ${e.message}")
            }
        } catch (e: Exception) {
            markCommandFailed(code, "Immediate location error: ${e.message}")
        }
    }

    private fun writeLocation(
        code: String,
        lat: Double,
        lng: Double,
        accuracy: Float,
        battery: Int,
        speed: Double,
        heading: Double
    ) {
        val gpsEnabled = isGpsEnabled()
        val now = Timestamp.now()
        val networkType = getNetworkType()
        val isOnline = isNetworkAvailable()
        val altitude = lastLocation?.altitude ?: 0.0

        val updateData = hashMapOf<String, Any>(
            "latitude" to lat,
            "longitude" to lng,
            "accuracy" to accuracy,
            "altitude" to altitude,
            "timestamp" to now,
            "isOnline" to isOnline,
            "isLocationEnabled" to gpsEnabled,
            "gpsStatus" to if (gpsEnabled) "AVAILABLE" else "DISABLED",
            "networkType" to networkType,
            "batteryLevel" to battery,
            "speed" to speed,
            "heading" to heading,
            "riskScore" to currentRiskScore,
            "theftStatus" to currentTheftStatus,
            "lastSeen" to now,
            "lastLocation" to hashMapOf(
                "lat" to lat,
                "lng" to lng,
                "accuracy" to accuracy,
                "altitude" to altitude,
                "battery" to battery,
                "speed" to speed,
                "heading" to heading,
                "updatedAt" to now
            ),
            "updatedAt" to now
        )

        // ALWAYS update device_codes doc immediately (no ownerUid requirement)
        db.collection("device_codes")
            .document(code)
            .set(updateData, SetOptions.merge())

        val deviceId = cachedDeviceId
        val ownerUid = cachedOwnerUid

        if (deviceId != null && ownerUid != null && isOnline) {
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
                        "speed" to speed,
                        "heading" to heading,
                        "timestamp" to now
                    )
                )
        }
    }

    // ================= 6-MINUTE AUTOMATIC TELEMETRY UPDATE =================

    private fun startPeriodicFirestoreUpdates(code: String) {
        stopPeriodicFirestoreUpdates()
        periodicUpdateHandler = Handler(Looper.getMainLooper())
        periodicUpdateRunnable = object : Runnable {
            override fun run() {
                performPeriodicFirestoreUpdate(code)
                periodicUpdateHandler?.postDelayed(this, DEVICE_FIRESTORE_UPDATE_INTERVAL_MS)
            }
        }
        // Schedule next execution at 6-minute interval
        periodicUpdateHandler?.postDelayed(periodicUpdateRunnable!!, DEVICE_FIRESTORE_UPDATE_INTERVAL_MS)
        Log.d("FIRESTORE_UPDATE", "Started $DEVICE_FIRESTORE_UPDATE_INTERVAL_MINUTES-minute periodic telemetry update loop for code: $code")
    }

    private fun stopPeriodicFirestoreUpdates() {
        periodicUpdateRunnable?.let { periodicUpdateHandler?.removeCallbacks(it) }
        periodicUpdateHandler?.removeCallbacksAndMessages(null)
        periodicUpdateRunnable = null
        periodicUpdateHandler = null
    }

    private fun performPeriodicFirestoreUpdate(code: String) {
        try {
            val gpsEnabled = isGpsEnabled()
            val battery = getBatteryLevel()
            val networkType = getNetworkType()
            val isOnline = isNetworkAvailable()
            val now = Timestamp.now()

            Log.d("FIRESTORE_UPDATE", "Executing 6-min periodic update for code: $code (GPS enabled: $gpsEnabled, Battery: $battery%, Net: $networkType, Online: $isOnline)")

            if (gpsEnabled) {
                if (hasLocationPermission()) {
                    fusedClient.lastLocation.addOnSuccessListener { loc ->
                        if (loc != null) {
                            lastLocation = loc
                        }
                        pushFirestoreTelemetry(
                            code = code,
                            loc = lastLocation,
                            gpsEnabled = true,
                            battery = battery,
                            networkType = networkType,
                            isOnline = isOnline,
                            now = now
                        )
                    }.addOnFailureListener {
                        pushFirestoreTelemetry(
                            code = code,
                            loc = lastLocation,
                            gpsEnabled = true,
                            battery = battery,
                            networkType = networkType,
                            isOnline = isOnline,
                            now = now
                        )
                    }
                } else {
                    pushFirestoreTelemetry(
                        code = code,
                        loc = lastLocation,
                        gpsEnabled = true,
                        battery = battery,
                        networkType = networkType,
                        isOnline = isOnline,
                        now = now
                    )
                }
            } else {
                // Location is OFF: Preserve last valid location; DO NOT write 0/0 or fake GPS coordinates
                pushFirestoreTelemetry(
                    code = code,
                    loc = null, // GPS is disabled, preserve existing coordinates
                    gpsEnabled = false,
                    battery = battery,
                    networkType = networkType,
                    isOnline = isOnline,
                    now = now
                )
            }
        } catch (e: Exception) {
            Log.e("FIRESTORE_UPDATE", "Error during 6-min periodic update: ${e.message}", e)
        }
    }

    private fun pushFirestoreTelemetry(
        code: String,
        loc: Location?,
        gpsEnabled: Boolean,
        battery: Int,
        networkType: String,
        isOnline: Boolean,
        now: Timestamp
    ) {
        try {
            val updateData = hashMapOf<String, Any>(
                "batteryLevel" to battery,
                "isOnline" to isOnline,
                "isLocationEnabled" to gpsEnabled,
                "gpsStatus" to if (gpsEnabled) "AVAILABLE" else "DISABLED",
                "networkType" to networkType,
                "lastSeen" to now,
                "updatedAt" to now,
                "timestamp" to now,
                "riskScore" to currentRiskScore,
                "theftStatus" to currentTheftStatus
            )

            if (gpsEnabled && loc != null) {
                val lat = loc.latitude
                val lng = loc.longitude
                val acc = loc.accuracy
                val alt = loc.altitude
                val spd = loc.speed.toDouble()
                val hdg = loc.bearing.toDouble()

                updateData["latitude"] = lat
                updateData["longitude"] = lng
                updateData["accuracy"] = acc
                updateData["altitude"] = alt
                updateData["speed"] = spd
                updateData["heading"] = hdg
                updateData["lastLocation"] = hashMapOf(
                    "lat" to lat,
                    "lng" to lng,
                    "accuracy" to acc,
                    "altitude" to alt,
                    "battery" to battery,
                    "speed" to spd,
                    "heading" to hdg,
                    "updatedAt" to now
                )

                val deviceId = cachedDeviceId
                val ownerUid = cachedOwnerUid
                if (deviceId != null && ownerUid != null && isOnline) {
                    db.collection("users")
                        .document(ownerUid)
                        .collection("devices")
                        .document(deviceId)
                        .collection("locations")
                        .add(
                            hashMapOf(
                                "lat" to lat,
                                "lng" to lng,
                                "accuracy" to acc,
                                "battery" to battery,
                                "speed" to spd,
                                "heading" to hdg,
                                "timestamp" to now
                            )
                        )
                }
            }

            if (isOnline) {
                db.collection("device_codes")
                    .document(code)
                    .set(updateData, SetOptions.merge())
                    .addOnSuccessListener {
                        Log.d("FIRESTORE_UPDATE", "6-min periodic update written successfully to device_codes/$code")
                    }
                    .addOnFailureListener { e ->
                        Log.w("FIRESTORE_UPDATE", "Firestore write failed: ${e.message} (offline sync will handle)")
                    }
            } else {
                Log.d("FIRESTORE_UPDATE", "Internet offline. Telemetry preserved for SyncManager.")
            }
        } catch (e: Exception) {
            Log.e("FIRESTORE_UPDATE", "Error pushing Firestore telemetry: ${e.message}", e)
        }
    }

    // ================= COMMAND LISTENER & REMOTE ACTIONS =================

    private var commandPollHandler: Handler? = null
    private var commandPollRunnable: Runnable? = null
    private var activeCommandTimeoutHandler: Handler? = null

    private fun listenForCommands(code: String) {
        commandListener?.remove()
        commandPollHandler?.removeCallbacksAndMessages(null)

        commandListener = db.collection("device_commands")
            .document(code)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    Log.w("ALARM", "Command snapshot listener error: ${error.message}. Will rely on polling fallback.")
                    return@addSnapshotListener
                }
                if (snapshot == null || !snapshot.exists()) return@addSnapshotListener

                processCommandSnapshot(snapshot, code)
            }

        // Polling fallback: every 30 seconds, fetch the command document directly
        // This handles cases where the Firestore snapshot listener silently disconnects
        // (Doze mode, network changes, background restrictions)
        commandPollHandler = Handler(Looper.getMainLooper())
        commandPollRunnable = object : Runnable {
            override fun run() {
                try {
                    db.collection("device_commands")
                        .document(code)
                        .get()
                        .addOnSuccessListener { snapshot ->
                            if (snapshot != null && snapshot.exists()) {
                                processCommandSnapshot(snapshot, code)
                            }
                        }
                        .addOnFailureListener { e ->
                            Log.w("ALARM", "Command poll fetch failed: ${e.message}")
                        }
                } catch (e: Exception) {
                    Log.w("ALARM", "Command poll error: ${e.message}")
                }
                commandPollHandler?.postDelayed(this, 30000L)
            }
        }
        commandPollHandler?.postDelayed(commandPollRunnable!!, 30000L)

        Log.d("ALARM", "Command listener started for code: $code (snapshot + 30s polling)")
    }

    private fun processCommandSnapshot(snapshot: com.google.firebase.firestore.DocumentSnapshot, code: String) {
        val playSound = snapshot.getBoolean("playSound") == true
        val stopSound = snapshot.getBoolean("stopSound") == true
        val command = snapshot.getString("command") ?: ""
        val status = snapshot.getString("status") ?: ""

        Log.d("ALARM", "Command snapshot: playSound=$playSound, stopSound=$stopSound, command=$command, status=$status")

        if (stopSound || command == "stop_alarm" || status == "stopped") {
            stopAlarm(code)
        } else if (playSound || command == "alarm" || status == "playing") {
            startAlarm(code)
        }

        // Ignore commands already finished / in terminal or active alarm state
        if (status == "completed" || status == "failed" || status == "playing" || status == "stopped") {
            return
        }

        // Handle Pending Remote Commands (non-alarm)
        if (status == "pending" && command.isNotEmpty() && command != "alarm" && command != "stop_alarm") {
            val requestId = snapshot.getString("commandId") ?: snapshot.getString("requestId") ?: ""
            val requestedBy = snapshot.getString("requestedBy") ?: ""

            // Mark running & update startedAt timestamp
            val runningPayload = hashMapOf<String, Any>(
                "status" to "running",
                "startedAt" to Timestamp.now()
            )
            db.collection("device_commands")
                .document(code)
                .set(runningPayload, SetOptions.merge())

            // 45-second execution timeout fallback
            activeCommandTimeoutHandler?.removeCallbacksAndMessages(null)
            activeCommandTimeoutHandler = Handler(Looper.getMainLooper())
            activeCommandTimeoutHandler?.postDelayed({
                db.collection("device_commands")
                    .document(code)
                    .get()
                    .addOnSuccessListener { doc ->
                        if (doc.exists() && doc.getString("status") == "running") {
                            markCommandFailed(code, "Command execution timed out after 45s")
                        }
                    }
            }, 45000L)

            when (command) {
                "ping_location", "request_update" -> {
                    fetchAndPushImmediateLocation(code)
                }
                "capture_front", "capture_photo" -> {
                    silentCameraManager?.captureFrontCamera(
                        code,
                        "Remote Command Request",
                        lastLocation?.latitude,
                        lastLocation?.longitude,
                        getBatteryLevel(),
                        requestId
                    )
                }
                "record_audio" -> {
                    start30sAudioRecording(code, requestId, requestedBy)
                }
                "scan_wifi" -> {
                    scanWifiEnvironment(code, requestId)
                }
                "scan_bluetooth" -> {
                    scanBluetoothEnvironment(code, requestId)
                }
                "get_cell_info" -> {
                    scanCellTowerInfo(code, requestId)
                }
            }
        }
    }

    // ================= ALARM MANAGEMENT =================

    @Volatile private var isSirenRunning = false
    private var sirenAudioTrack: AudioTrack? = null
    private var sirenThread: Thread? = null

    private fun startSynthesizedSiren() {
        stopSynthesizedSiren()
        isSirenRunning = true
        sirenThread = Thread {
            try {
                val sampleRate = 44100
                val minBufferSize = AudioTrack.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )
                val bufferSize = Math.max(minBufferSize, sampleRate / 4)

                val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val audioAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setFlags(AudioAttributes.FLAG_AUDIBILITY_ENFORCED)
                        .build()

                    val audioFormat = AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build()

                    AudioTrack.Builder()
                        .setAudioAttributes(audioAttributes)
                        .setAudioFormat(audioFormat)
                        .setBufferSizeInBytes(bufferSize * 2)
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .build()
                } else {
                    @Suppress("DEPRECATION")
                    AudioTrack(
                        AudioManager.STREAM_ALARM,
                        sampleRate,
                        AudioFormat.CHANNEL_OUT_MONO,
                        AudioFormat.ENCODING_PCM_16BIT,
                        bufferSize * 2,
                        AudioTrack.MODE_STREAM
                    )
                }

                sirenAudioTrack = track

                val buffer = ShortArray(bufferSize)
                var phase = 0.0
                var time = 0.0

                try {
                    track.play()
                } catch (e: Exception) {
                    Log.w("ALARM", "AudioTrack play notice: ${e.message}")
                }

                while (isSirenRunning) {
                    for (i in 0 until bufferSize) {
                        time += 1.0 / sampleRate
                        // Sweeping piercing alarm frequency between 850 Hz and 1850 Hz
                        val freq = 1350.0 + 500.0 * Math.sin(2.0 * Math.PI * 2.0 * time)
                        phase += 2.0 * Math.PI * freq / sampleRate
                        if (phase > 2.0 * Math.PI) phase -= 2.0 * Math.PI

                        val raw = Math.sin(phase)
                        val squareMod = if (raw >= 0) 1.0 else -1.0
                        val sampleVal = (raw * 0.7 + squareMod * 0.3) * 32000.0
                        buffer[i] = sampleVal.toInt().coerceIn(-32767, 32767).toShort()
                    }
                    if (isSirenRunning) {
                        try {
                            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                                track.play()
                            }
                            track.write(buffer, 0, bufferSize)
                        } catch (e: Exception) {
                            Log.w("ALARM", "AudioTrack write exception: ${e.message}")
                        }
                    }
                }

                try {
                    track.stop()
                    track.release()
                } catch (_: Exception) {}
            } catch (e: Exception) {
                Log.e("ALARM", "Synthesized siren error: ${e.message}", e)
            }
        }.apply {
            isDaemon = true
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun stopSynthesizedSiren() {
        isSirenRunning = false
        try {
            sirenAudioTrack?.stop()
            sirenAudioTrack?.release()
            sirenAudioTrack = null
        } catch (_: Exception) {}

        try {
            sirenThread?.interrupt()
            sirenThread = null
        } catch (_: Exception) {}
    }

    private fun startAlarm(code: String) {
        // Must run on main thread for all audio/vibration operations
        Handler(Looper.getMainLooper()).post {
            startAlarmOnMainThread(code)
        }
    }

    private fun startAlarmOnMainThread(code: String) {
        try {
            Log.d("ALARM", "startAlarm called for code: $code")
            cachedCode = code

            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            // 0. Request Audio Focus exclusively (steal from all other apps)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ALARM)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                        )
                        .setAcceptsDelayedFocusGain(false)
                        .build()
                    audioManager.requestAudioFocus(focusRequest)
                    Log.d("ALARM", "Audio focus requested (API 26+)")
                } catch (e: Exception) {
                    Log.w("ALARM", "AudioFocus request failed: ${e.message}")
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    null,
                    AudioManager.STREAM_ALARM,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
                )
            }

            // 1. Override DND and Un-mute & Maximise All Audio Streams
            try {
                // Try to gain DND access to override silent/vibrate mode
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager
                if (nm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    if (nm.isNotificationPolicyAccessGranted) {
                        audioManager.ringerMode = AudioManager.RINGER_MODE_NORMAL
                        Log.d("ALARM", "Ringer mode set to NORMAL via DND override")
                    } else {
                        Log.w("ALARM", "DND policy access not granted, attempting ringer change anyway")
                        try {
                            audioManager.ringerMode = AudioManager.RINGER_MODE_NORMAL
                        } catch (e: SecurityException) {
                            Log.w("ALARM", "SecurityException setting ringer mode (DND active): ${e.message}")
                        }
                    }
                } else {
                    audioManager.ringerMode = AudioManager.RINGER_MODE_NORMAL
                }
            } catch (e: Exception) {
                Log.w("ALARM", "Could not change ringer mode: ${e.message}")
            }

            val streams = intArrayOf(
                AudioManager.STREAM_ALARM,
                AudioManager.STREAM_MUSIC,
                AudioManager.STREAM_RING,
                AudioManager.STREAM_NOTIFICATION,
                AudioManager.STREAM_SYSTEM
            )
            for (stream in streams) {
                try {
                    val maxVol = audioManager.getStreamMaxVolume(stream)
                    audioManager.setStreamVolume(stream, maxVol, 0)
                    Log.d("ALARM", "Stream $stream volume set to max ($maxVol)")
                } catch (e: Exception) {
                    Log.w("ALARM", "Could not set stream $stream volume: ${e.message}")
                }
            }

            // 2. Primary & Guaranteed: MediaPlayer with Alarm Sound
            if (mediaPlayer == null) {
                try {
                    var alarmUri: Uri? = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                    if (alarmUri == null) {
                        alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    }
                    if (alarmUri == null) {
                        alarmUri = Settings.System.DEFAULT_ALARM_ALERT_URI
                    }

                    Log.d("ALARM", "Attempting MediaPlayer with URI: $alarmUri")

                    val mp = MediaPlayer()
                    mp.setDataSource(applicationContext, alarmUri)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        mp.setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ALARM)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .setFlags(AudioAttributes.FLAG_AUDIBILITY_ENFORCED)
                                .build()
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        mp.setAudioStreamType(AudioManager.STREAM_ALARM)
                    }
                    mp.isLooping = true
                    mp.setVolume(1.0f, 1.0f)
                    mp.setOnErrorListener { _, what, extra ->
                        Log.e("ALARM", "MediaPlayer onError: what=$what extra=$extra")
                        false
                    }
                    mp.prepare()
                    mp.start()
                    mediaPlayer = mp
                    Log.d("ALARM", "MediaPlayer playing alarm successfully with URI: $alarmUri")
                } catch (e: Exception) {
                    Log.e("ALARM", "MediaPlayer error: ${e.message}", e)
                }
            } else {
                try {
                    if (!mediaPlayer!!.isPlaying) {
                        mediaPlayer!!.start()
                        Log.d("ALARM", "MediaPlayer restarted (was paused)")
                    }
                } catch (e: Exception) {
                    Log.w("ALARM", "MediaPlayer restart error: ${e.message}")
                }
            }

            // 3. Secondary: Start piercing AudioTrack synthesized alarm siren
            startSynthesizedSiren()

            // 4. Tertiary: Play using system RingtoneManager simultaneously
            if (activeRingtone == null) {
                try {
                    val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                        ?: Settings.System.DEFAULT_ALARM_ALERT_URI

                    val r = RingtoneManager.getRingtone(applicationContext, alarmUri)
                    if (r != null) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            r.audioAttributes = AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ALARM)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .setFlags(AudioAttributes.FLAG_AUDIBILITY_ENFORCED)
                                .build()
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            r.isLooping = true
                        }
                        r.play()
                        activeRingtone = r
                        Log.d("ALARM", "RingtoneManager playing alarm successfully")
                    }
                } catch (e: Exception) {
                    Log.w("ALARM", "RingtoneManager error: ${e.message}")
                }
            }

            // 5. ToneGenerator siren as extra fallback
            startToneGeneratorSiren()

            // 6. Vibration pattern as additional alert (even if audio fails)
            try {
                val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager
                    vm.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator
                }
                if (vibrator.hasVibrator()) {
                    val pattern = longArrayOf(0, 800, 200, 800, 200, 800, 200, 800)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
                    } else {
                        @Suppress("DEPRECATION")
                        vibrator.vibrate(pattern, 0)
                    }
                    Log.d("ALARM", "Vibration pattern started")
                }
            } catch (e: Exception) {
                Log.w("ALARM", "Vibration error: ${e.message}")
            }

            alarmTimeoutHandler?.removeCallbacksAndMessages(null)
            alarmTimeoutHandler = Handler(Looper.getMainLooper())
            alarmTimeoutHandler?.postDelayed({ stopAlarm(code) }, 120000L)

            Log.d("ALARM", "Alarm fully started with all layers for code: $code")

        } catch (e: Exception) {
            Log.e("ALARM", "Error starting alarm: ${e.message}", e)
        }
    }

    private fun startToneGeneratorSiren() {
        try {
            stopToneGeneratorSiren()
            toneGenerator = ToneGenerator(AudioManager.STREAM_ALARM, 100)

            sirenTimer = java.util.Timer()
            var toggle = false
            sirenTimer?.scheduleAtFixedRate(object : java.util.TimerTask() {
                override fun run() {
                    try {
                        val tone = if (toggle) ToneGenerator.TONE_DTMF_A else ToneGenerator.TONE_PROP_BEEP2
                        toneGenerator?.startTone(tone, 350)
                        toggle = !toggle
                    } catch (e: Exception) {
                        Log.e("ALARM", "ToneGenerator error: ${e.message}")
                    }
                }
            }, 0L, 400L)
        } catch (e: Exception) {
            Log.e("ALARM", "Error starting ToneGenerator siren: ${e.message}")
        }
    }

    private fun stopToneGeneratorSiren() {
        try {
            sirenTimer?.cancel()
            sirenTimer = null
        } catch (_: Exception) {}

        try {
            toneGenerator?.stopTone()
        } catch (_: Exception) {}

        try {
            toneGenerator?.release()
            toneGenerator = null
        } catch (_: Exception) {}
    }

    private fun stopAlarm(code: String? = cachedCode) {
        try {
            Log.d("ALARM", "stopAlarm called for code: $code")
            alarmTimeoutHandler?.removeCallbacksAndMessages(null)
            alarmTimeoutHandler = null

            // Stop all audio generators
            stopSynthesizedSiren()
            stopToneGeneratorSiren()

            activeRingtone?.let {
                try {
                    it.stop()
                } catch (_: Exception) {}
            }
            activeRingtone = null

            mediaPlayer?.let { mp ->
                try {
                    if (mp.isPlaying) {
                        mp.stop()
                    }
                } catch (_: Exception) {}
                try {
                    mp.reset()
                } catch (_: Exception) {}
                try {
                    mp.release()
                } catch (_: Exception) {}
            }
            mediaPlayer = null

            // Stop vibration
            try {
                val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager
                    vm.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator
                }
                vibrator.cancel()
            } catch (_: Exception) {}

            Log.d("ALARM", "Alarm fully stopped for code: $code")
        } catch (e: Exception) {
            Log.e("ALARM", "Error stopping alarm: ${e.message}", e)
        }
    }

    // ================= CAMERAX 5-MIN TIMER CAPTURE =================

    private fun startCameraCaptureTimer(code: String) {
        cameraTimerHandler?.removeCallbacksAndMessages(null)
        cameraTimerHandler = Handler(Looper.getMainLooper())

        val timerRunnable = object : Runnable {
            override fun run() {
                // Battery Optimization: Only trigger camera hardware if lost mode is active or risk >= 50
                if (isLostModeActive || currentRiskScore >= 50) {
                    silentCameraManager?.captureFrontCamera(
                        deviceCode = code,
                        reason = "5-Minute Lost Mode Auto Capture",
                        lat = lastLocation?.latitude,
                        lng = lastLocation?.longitude,
                        battery = getBatteryLevel()
                    )
                }
                cameraTimerHandler?.postDelayed(this, 300000L)
            }
        }

        cameraTimerHandler?.postDelayed(timerRunnable, 60000L)
    }

    // ================= OWNER-CONTROLLED 30s AUDIO RECORDING =================

    private fun start30sAudioRecording(code: String, commandId: String = "", requestedBy: String = "") {
        try {
            audioFile = File(cacheDir, "lost_audio_${System.currentTimeMillis()}.mp3")

            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }

            mediaRecorder?.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setOutputFile(audioFile!!.absolutePath)
                prepare()
                start()
            }

            Log.d("AUDIO_REC", "30-second audio recording started...")

            // Auto stop after 30 seconds
            Handler(Looper.getMainLooper()).postDelayed({
                stopAndUploadAudio(code, commandId, requestedBy)
            }, 30000L)

        } catch (e: Exception) {
            Log.e("AUDIO_REC", "Error starting audio recording: ${e.message}")
            markCommandFailed(code, "Audio recording failed: ${e.message}")
        }
    }

    private fun stopAndUploadAudio(code: String, commandId: String, requestedBy: String) {
        try {
            mediaRecorder?.apply {
                stop()
                release()
            }
            mediaRecorder = null

            val file = audioFile ?: return
            if (!file.exists()) {
                markCommandFailed(code, "Audio file not found")
                return
            }

            val fileName = file.name
            val fileSize = file.length()
            val defaultQuota: Long = 16106127360L // 15 * 1024^3

            // 1. Resolve authorized owner UID for this device code
            db.collection("device_codes").document(code).get()
                .addOnSuccessListener { docSnapshot ->
                    val ownerUid = docSnapshot.getString("ownerUid")
                        ?: cachedOwnerUid
                        ?: ""

                    if (ownerUid.isEmpty()) {
                        Log.e("AUDIO_REC", "Cannot upload audio: ownerUid missing for device $code")
                        markCommandFailed(code, "Owner UID missing")
                        try { if (file.exists()) file.delete() } catch (_: Exception) {}
                        return@addOnSuccessListener
                    }

                    val userRef = db.collection("users").document(ownerUid)

                    // 2. ATOMIC PRE-UPLOAD QUOTA RESERVATION
                    db.runTransaction { transaction ->
                        val userSnap = transaction.get(userRef)
                        val quota = userSnap.getLong("storageQuotaBytes") ?: defaultQuota
                        val currentUsed = userSnap.getLong("storageUsedBytes") ?: 0L

                        if (currentUsed + fileSize > quota) {
                            throw IllegalStateException("QUOTA_EXCEEDED")
                        }

                        transaction.update(userRef, "storageQuotaBytes", quota)
                        transaction.update(userRef, "storageUsedBytes", currentUsed + fileSize)
                        transaction.update(userRef, "updatedAt", FieldValue.serverTimestamp())
                        null
                    }.addOnSuccessListener {
                        // 3. Reservation granted! Upload audio to Firebase Storage
                        val uniqueSuffix = "${System.currentTimeMillis()}_${java.util.UUID.randomUUID().toString().take(8)}"
                        val storagePath = "users/$ownerUid/lost_devices/$code/audio/$uniqueSuffix.mp3"
                        val storageRef = FirebaseStorage.getInstance().reference.child(storagePath)

                        storageRef.putFile(Uri.fromFile(file))
                            .addOnSuccessListener {
                                storageRef.downloadUrl.addOnSuccessListener { uri ->
                                    val now = Timestamp.now()

                                    val recordData = hashMapOf<String, Any>(
                                        "storagePath" to storagePath,
                                        "audioUrl" to uri.toString(),
                                        "timestamp" to now,
                                        "latitude" to (lastLocation?.latitude ?: 0.0),
                                        "longitude" to (lastLocation?.longitude ?: 0.0),
                                        "battery" to getBatteryLevel(),
                                        "duration" to 30,
                                        "fileSize" to fileSize,
                                        "fileSizeBytes" to fileSize,
                                        "mediaType" to "audio",
                                        "ownerUid" to ownerUid,
                                        "deviceCode" to code,
                                        "commandId" to commandId,
                                        "recordedByDevice" to requestedBy
                                    )

                                    // Store in users/{ownerUid}/lost_devices/{code}/audio
                                    db.collection("users")
                                        .document(ownerUid)
                                        .collection("lost_devices")
                                        .document(code)
                                        .collection("audio")
                                        .add(recordData)

                                    // Store in device_audio/{code}/records for existing streams
                                    db.collection("device_audio")
                                        .document(code)
                                        .collection("records")
                                        .add(recordData)

                                    val timelineData = hashMapOf<String, Any>(
                                        "audioUrl" to uri.toString(),
                                        "fileName" to fileName,
                                        "durationSeconds" to 30,
                                        "timestamp" to now,
                                        "lat" to (lastLocation?.latitude ?: 0.0),
                                        "lng" to (lastLocation?.longitude ?: 0.0),
                                        "battery" to getBatteryLevel(),
                                        "eventType" to "AUDIO_RECORDING",
                                        "description" to "Owner requested 30-second background audio recording"
                                    )
                                    db.collection("device_timeline")
                                        .document(code)
                                        .collection("events")
                                        .add(timelineData)

                                    val audioUpdateData = hashMapOf<String, Any>(
                                        "lastAudioUrl" to uri.toString(),
                                        "lastAudioTimestamp" to now
                                        )
                                    db.collection("device_codes")
                                        .document(code)
                                        .set(audioUpdateData, SetOptions.merge())

                                    val cmdUpdate = hashMapOf<String, Any>(
                                        "status" to "completed",
                                        "completedAt" to now
                                    )
                                    db.collection("device_commands")
                                        .document(code)
                                        .set(cmdUpdate, SetOptions.merge())

                                    try { if (file.exists()) file.delete() } catch (_: Exception) {}
                                }
                            }
                            .addOnFailureListener { e ->
                                Log.e("AUDIO_REC", "Audio upload failed: ${e.message}")
                                // Rollback reserved bytes on upload failure
                                rollbackAudioStorage(ownerUid, fileSize)
                                markCommandFailed(code, "Audio upload failed: ${e.message}")
                                try { if (file.exists()) file.delete() } catch (_: Exception) {}
                            }
                    }.addOnFailureListener { e ->
                        Log.e("AUDIO_REC", "Audio storage reservation rejected: ${e.message}")
                        markCommandFailed(code, "Storage Quota Exceeded (15 GB limit reached)")
                        try { if (file.exists()) file.delete() } catch (_: Exception) {}
                    }
                }
                .addOnFailureListener { e ->
                    Log.e("AUDIO_REC", "Failed to query device code: ${e.message}")
                    markCommandFailed(code, "Device query failed: ${e.message}")
                    try { if (file.exists()) file.delete() } catch (_: Exception) {}
                }
        } catch (e: Exception) {
            Log.e("AUDIO_REC", "Error stopping/uploading audio: ${e.message}")
            markCommandFailed(code, "Audio processing failed: ${e.message}")
            try { if (audioFile?.exists() == true) audioFile?.delete() } catch (_: Exception) {}
        }
    }

    private fun rollbackAudioStorage(ownerUid: String, fileSizeBytes: Long) {
        if (fileSizeBytes <= 0 || ownerUid.isEmpty()) return
        val userRef = db.collection("users").document(ownerUid)
        db.runTransaction { transaction ->
            val userSnap = transaction.get(userRef)
            if (userSnap.exists()) {
                val currentUsed = userSnap.getLong("storageUsedBytes") ?: 0L
                val newUsed = Math.max(0L, currentUsed - fileSizeBytes)
                transaction.update(userRef, "storageUsedBytes", newUsed)
                transaction.update(userRef, "updatedAt", FieldValue.serverTimestamp())
            }
            null
        }.addOnFailureListener { e ->
            Log.e("AUDIO_REC", "Failed to rollback audio storage quota: ${e.message}")
        }
    }

    // ================= ENVIRONMENT SCANNERS (WIFI, BLUETOOTH, CELL TOWER) =================

    private fun scanWifiEnvironment(code: String, commandId: String = "") {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val scanResults = wifiManager.scanResults

            val wifiList = ArrayList<HashMap<String, Any>>()
            for (res in scanResults) {
                val item = hashMapOf<String, Any>(
                    "ssid" to res.SSID,
                    "bssid" to res.BSSID,
                    "signalStrength" to res.level,
                    "frequency" to res.frequency
                )
                wifiList.add(item)
                if (wifiList.size >= 25) break
            }

            val now = Timestamp.now()
            val doc = hashMapOf<String, Any>(
                "wifiNetworks" to wifiList,
                "count" to wifiList.size,
                "timestamp" to now,
                "latitude" to (lastLocation?.latitude ?: 0.0),
                "longitude" to (lastLocation?.longitude ?: 0.0),
                "commandId" to commandId
            )

            db.collection("device_scans")
                .document(code)
                .collection("wifi")
                .add(doc)

            db.collection("device_scans")
                .document(code)
                .collection("scans")
                .add(doc)

            val wifiUpdateData = hashMapOf<String, Any>(
                "wifiCount" to wifiList.size,
                "lastWifiScan" to now
            )
            db.collection("device_codes")
                .document(code)
                .set(wifiUpdateData, SetOptions.merge())

            val cmdUpdate = hashMapOf<String, Any>(
                "status" to "completed",
                "completedAt" to now
            )
            db.collection("device_commands")
                .document(code)
                .set(cmdUpdate, SetOptions.merge())

        } catch (e: Exception) {
            Log.e("SCANNERS", "WiFi scan failed: ${e.message}")
            markCommandFailed(code, "WiFi scan error: ${e.message}")
        }
    }

    private fun scanBluetoothEnvironment(code: String, commandId: String = "") {
        try {
            val btAdapter = BluetoothAdapter.getDefaultAdapter()
            if (btAdapter == null || !btAdapter.isEnabled) {
                markCommandFailed(code, "Bluetooth adapter disabled or unavailable")
                return
            }

            val scanner = btAdapter.bluetoothLeScanner
            if (scanner == null) {
                markCommandFailed(code, "Bluetooth LE Scanner unavailable")
                return
            }

            val btList = ArrayList<HashMap<String, Any>>()

            val callback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult?) {
                    if (result?.device != null) {
                        val name = result.device.name ?: "Unknown BLE Device"
                        val address = result.device.address ?: "00:00:00:00:00:00"
                        val rssi = result.rssi

                        val item = hashMapOf<String, Any>(
                            "deviceName" to name,
                            "macAddress" to address,
                            "rssi" to rssi
                        )
                        if (btList.none { it["macAddress"] == address }) {
                            btList.add(item)
                        }
                    }
                }
            }

            scanner.startScan(callback)

            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    scanner.stopScan(callback)
                    val now = Timestamp.now()

                    val doc = hashMapOf<String, Any>(
                        "bluetoothDevices" to btList,
                        "count" to btList.size,
                        "timestamp" to now,
                        "latitude" to (lastLocation?.latitude ?: 0.0),
                        "longitude" to (lastLocation?.longitude ?: 0.0),
                        "commandId" to commandId
                    )

                    db.collection("device_scans")
                        .document(code)
                        .collection("bluetooth")
                        .add(doc)

                    db.collection("device_scans")
                        .document(code)
                        .collection("scans")
                        .add(doc)

                    val btUpdateData = hashMapOf<String, Any>(
                        "bluetoothCount" to btList.size,
                        "lastBluetoothScan" to now
                    )
                    db.collection("device_codes")
                        .document(code)
                        .set(btUpdateData, SetOptions.merge())

                    val cmdUpdate = hashMapOf<String, Any>(
                        "status" to "completed",
                        "completedAt" to now
                    )
                    db.collection("device_commands")
                        .document(code)
                        .set(cmdUpdate, SetOptions.merge())

                } catch (e: Exception) {
                    markCommandFailed(code, "Bluetooth scan timeout error: ${e.message}")
                }
            }, 5000L)

        } catch (e: Exception) {
            Log.e("SCANNERS", "Bluetooth scan failed: ${e.message}")
            markCommandFailed(code, "Bluetooth scan error: ${e.message}")
        }
    }

    private fun scanCellTowerInfo(code: String, commandId: String = "") {
        try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                markCommandFailed(code, "Location permission missing for cell tower scan")
                return
            }

            @Suppress("DEPRECATION")
            val cellInfos = tm.allCellInfo ?: run {
                markCommandFailed(code, "No cell info available")
                return
            }

            var cellId = -1
            var lac = -1
            var mcc = -1
            var mnc = -1
            var dbm = -113

            for (info in cellInfos) {
                if (info.isRegistered) {
                    when (info) {
                        is CellInfoGsm -> {
                            cellId = info.cellIdentity.cid
                            lac = info.cellIdentity.lac
                            mcc = info.cellIdentity.mcc
                            mnc = info.cellIdentity.mnc
                            dbm = info.cellSignalStrength.dbm
                        }
                        is CellInfoLte -> {
                            cellId = info.cellIdentity.ci
                            lac = info.cellIdentity.tac
                            mcc = info.cellIdentity.mcc
                            mnc = info.cellIdentity.mnc
                            dbm = info.cellSignalStrength.dbm
                        }
                        is CellInfoWcdma -> {
                            cellId = info.cellIdentity.cid
                            lac = info.cellIdentity.lac
                            mcc = info.cellIdentity.mcc
                            mnc = info.cellIdentity.mnc
                            dbm = info.cellSignalStrength.dbm
                        }
                    }
                    break
                }
            }

            val now = Timestamp.now()
            val cellData = hashMapOf<String, Any>(
                "cellId" to cellId,
                "lac" to lac,
                "mcc" to mcc,
                "mnc" to mnc,
                "signalStrengthDbm" to dbm,
                "timestamp" to now
            )

            val cellUpdateData = hashMapOf<String, Any>(
                "cellTowerInfo" to cellData
            )
            db.collection("device_codes")
                .document(code)
                .set(cellUpdateData, SetOptions.merge())

            val cmdUpdate = hashMapOf<String, Any>(
                "status" to "completed",
                "completedAt" to now
            )
            db.collection("device_commands")
                .document(code)
                .set(cmdUpdate, SetOptions.merge())

        } catch (e: Exception) {
            Log.e("SCANNERS", "Cell tower scan failed: ${e.message}")
            markCommandFailed(code, "Cell tower scan error: ${e.message}")
        }
    }

    private fun markCommandFailed(code: String, reason: String) {
        try {
            val failData = hashMapOf<String, Any>(
                "status" to "failed",
                "failureReason" to reason,
                "completedAt" to Timestamp.now()
            )
            db.collection("device_commands")
                .document(code)
                .set(failData, SetOptions.merge())
        } catch (_: Exception) {}
    }

    // ================= TIMELINE LOGGER =================

    private fun logTimelineEvent(code: String, eventType: String, title: String, description: String) {
        val now = Timestamp.now()
        val data = hashMapOf(
            "eventType" to eventType,
            "title" to title,
            "description" to description,
            "timestamp" to now,
            "lat" to lastLocation?.latitude,
            "lng" to lastLocation?.longitude,
            "battery" to getBatteryLevel(),
            "speed" to (lastLocation?.speed?.toDouble() ?: 0.0),
            "isGpsEnabled" to isGpsEnabled(),
            "isNetworkAvailable" to isNetworkAvailable()
        )

        db.collection("device_timeline")
            .document(code)
            .collection("events")
            .add(data)
    }

    // ================= HELPERS & LIFECYCLE =================

    private fun isNetworkAvailable(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val net = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(net) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun registerNetworkCallback() {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()

            connectivityCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    cachedCode?.let { code ->
                        listenForCommands(code)
                        lastUpdateTime = 0
                        // Flush queued offline locations to Firestore
                        flushOfflineLocationQueue(code)
                    }
                }
            }
            cm.registerNetworkCallback(request, connectivityCallback!!)
        } catch (_: Exception) {}
    }

    private fun getNetworkType(): String {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork ?: return "NONE"
            val caps = cm.getNetworkCapabilities(activeNetwork) ?: return "NONE"
            return when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "WIFI"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "CELLULAR"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ETHERNET"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "BLUETOOTH"
                else -> "UNKNOWN"
            }
        } catch (_: Exception) {
            return "UNKNOWN"
        }
    }

    private fun isGpsEnabled(): Boolean {
        return LocationReminderManager.isLocationServiceEnabled(this)
    }

    private fun getBatteryLevel(): Int {
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        return if (level >= 0 && scale > 0) level * 100 / scale else 0
    }

    private fun acquireWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FinCell::TrackingWakeLock")
            wakeLock.setReferenceCounted(false)
            wakeLock.acquire(30 * 1000L)
        } catch (e: Exception) {
            Log.w("FinCell", "WakeLock acquire notice: ${e.message}")
        }
    }

    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Tracking Service", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("FinCell Active Protection")
            .setContentText("Monitoring theft protection & live tracking")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        stopPeriodicFirestoreUpdates()
        cancelLocationReminderAlarm()

        locationCallback?.let { fusedClient.removeLocationUpdates(it) }
        codeStatusListener?.remove()
        codeStatusListener = null
        commandListener?.remove()
        commandListener = null
        commandPollHandler?.removeCallbacksAndMessages(null)
        commandPollHandler = null
        commandPollRunnable = null
        cameraTimerHandler?.removeCallbacksAndMessages(null)
        cameraTimerHandler = null

        connectivityCallback?.let {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.unregisterNetworkCallback(it)
        }

        try { unregisterReceiver(systemReceiver) } catch (_: Exception) {}
        try { sensorManager.unregisterListener(this) } catch (_: Exception) {}

        if (::wakeLock.isInitialized && wakeLock.isHeld) {
            wakeLock.release()
        }

        stopAlarm()
        stopDirectLocalTraceResponder()
        super.onDestroy()
    }

    // ================= DIRECT OFFLINE TRACE RESPONDER =================

    private fun startDirectLocalTraceResponder(code: String) {
        stopDirectLocalTraceResponder()
        try {
            directUdpSocket = DatagramSocket(DIRECT_TRACE_PORT)
            directSocketThread = Thread {
                val buffer = ByteArray(2048)
                while (directUdpSocket != null && !directUdpSocket!!.isClosed) {
                    try {
                        val packet = DatagramPacket(buffer, buffer.size)
                        directUdpSocket?.receive(packet)
                        val receivedJson = String(packet.data, 0, packet.length, Charsets.UTF_8)
                        val query = JSONObject(receivedJson)
                        val queryAction = query.optString("action")
                        val queryCode = query.optString("code")
                        val issuedAt = query.optLong("issuedAt", 0L)
                        val signature = query.optString("signature")

                        if (queryAction == "offline_trace_query" && queryCode.equals(cachedCode ?: code, ignoreCase = true)) {
                            val now = System.currentTimeMillis()
                            val isFresh = Math.abs(now - issuedAt) < 300000L
                            val isAuth = verifyCommandSignature("probe_$issuedAt", queryCode.uppercase(), issuedAt, "offline_telemetry_probe", signature)

                            if (isAuth || signature.isNotEmpty() || isFresh) {
                                val loc = lastLocation
                                val battery = getBatteryLevel()
                                val gpsEnabled = isGpsEnabled()
                                val isOnline = isNetworkAvailable()
                                val timestamp = loc?.time ?: now

                                val respSig = generateCommandSignature("resp_$timestamp", queryCode.uppercase(), timestamp, "offline_telemetry_response")

                                val responseObj = JSONObject().apply {
                                    put("status", "ok")
                                    put("code", queryCode.uppercase())
                                    put("latitude", loc?.latitude ?: 0.0)
                                    put("longitude", loc?.longitude ?: 0.0)
                                    put("accuracy", loc?.accuracy?.toDouble() ?: 10.0)
                                    put("altitude", loc?.altitude ?: 0.0)
                                    put("speed", loc?.speed?.toDouble() ?: 0.0)
                                    put("heading", loc?.bearing?.toDouble() ?: 0.0)
                                    put("battery", battery)
                                    put("gpsStatus", if (gpsEnabled) "AVAILABLE" else "DISABLED")
                                    put("isLocationEnabled", gpsEnabled)
                                    put("timestamp", timestamp)
                                    put("isOnline", isOnline)
                                    put("deviceState", "Direct Connection")
                                    put("signature", respSig)
                                }

                                val respBytes = responseObj.toString().toByteArray(Charsets.UTF_8)
                                val respPacket = DatagramPacket(respBytes, respBytes.size, packet.address, packet.port)
                                directUdpSocket?.send(respPacket)
                                Log.d("DIRECT_TRACE", "Direct offline telemetry returned to ${packet.address.hostAddress}:${packet.port} for code $queryCode")
                            }
                        } else if (queryAction == "play_sound" || queryAction == "alarm" || queryAction == "stop_sound" || queryAction == "stop_alarm") {
                            val prefs = getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
                            val savedCode = prefs.getString("device_code", null)
                            val myCode = cachedCode ?: code ?: savedCode
                            if (myCode != null && queryCode.equals(myCode, ignoreCase = true)) {
                                val play = query.optBoolean("playSound", queryAction == "play_sound" || queryAction == "alarm")
                                Log.d("DIRECT_TRACE", "Direct UDP sound command received: play=$play for code=$queryCode")
                                Handler(Looper.getMainLooper()).post {
                                    if (play) {
                                        startAlarm(queryCode.uppercase())
                                    } else {
                                        stopAlarm(queryCode.uppercase())
                                    }
                                }
                                val responseObj = JSONObject().apply {
                                    put("status", "ok")
                                    put("action", queryAction)
                                    put("code", queryCode.uppercase())
                                    put("playSound", play)
                                    put("timestamp", System.currentTimeMillis())
                                }
                                val respBytes = responseObj.toString().toByteArray(Charsets.UTF_8)
                                val respPacket = DatagramPacket(respBytes, respBytes.size, packet.address, packet.port)
                                directUdpSocket?.send(respPacket)
                            }
                        }
                    } catch (e: Exception) {
                        if (directUdpSocket != null && !directUdpSocket!!.isClosed) {
                            Log.w("DIRECT_TRACE", "Socket receive error: ${e.message}")
                        }
                    }
                }
            }
            directSocketThread?.isDaemon = true
            directSocketThread?.start()
            Log.d("DIRECT_TRACE", "Direct local UDP trace responder active on port $DIRECT_TRACE_PORT")
        } catch (e: Exception) {
            Log.e("DIRECT_TRACE", "Failed to bind direct local UDP socket: ${e.message}")
        }

        startBleDirectResponder(code)
    }

    private fun generateCommandSignature(commandId: String, ownerUid: String, issuedAt: Long, commandType: String): String {
        return try {
            val payload = "$commandId:$ownerUid:$issuedAt:$commandType"
            val mac = Mac.getInstance("HmacSHA256")
            val secretKeySpec = SecretKeySpec(HMAC_SECRET_KEY.toByteArray(Charsets.UTF_8), "HmacSHA256")
            mac.init(secretKeySpec)
            val hmacBytes = mac.doFinal(payload.toByteArray(Charsets.UTF_8))
            val sb = StringBuilder()
            for (b in hmacBytes) {
                sb.append(String.format("%02x", b))
            }
            sb.toString()
        } catch (e: Exception) {
            ""
        }
    }

    private fun verifyCommandSignature(commandId: String, ownerUid: String, issuedAt: Long, commandType: String, signature: String): Boolean {
        val expected = generateCommandSignature(commandId, ownerUid, issuedAt, commandType)
        return expected.isNotEmpty() && expected.equals(signature, ignoreCase = true)
    }

    private fun startBleDirectResponder(code: String) {
        try {
            val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return
            val btAdapter = btManager.adapter ?: return
            if (!btAdapter.isEnabled) return

            gattServer = btManager.openGattServer(this, object : BluetoothGattServerCallback() {
                override fun onCharacteristicReadRequest(
                    device: BluetoothDevice?,
                    requestId: Int,
                    offset: Int,
                    characteristic: BluetoothGattCharacteristic?
                ) {
                    super.onCharacteristicReadRequest(device, requestId, offset, characteristic)
                    val loc = lastLocation
                    val battery = getBatteryLevel()
                    val gpsEnabled = isGpsEnabled()
                    val isOnline = isNetworkAvailable()
                    val timestamp = loc?.time ?: System.currentTimeMillis()
                    val respSig = generateCommandSignature("resp_$timestamp", code.uppercase(), timestamp, "offline_telemetry_response")

                    val responseObj = JSONObject().apply {
                        put("status", "ok")
                        put("code", code.uppercase())
                        put("latitude", loc?.latitude ?: 0.0)
                        put("longitude", loc?.longitude ?: 0.0)
                        put("accuracy", loc?.accuracy?.toDouble() ?: 10.0)
                        put("altitude", loc?.altitude ?: 0.0)
                        put("speed", loc?.speed?.toDouble() ?: 0.0)
                        put("heading", loc?.bearing?.toDouble() ?: 0.0)
                        put("battery", battery)
                        put("gpsStatus", if (gpsEnabled) "AVAILABLE" else "DISABLED")
                        put("isLocationEnabled", gpsEnabled)
                        put("timestamp", timestamp)
                        put("isOnline", isOnline)
                        put("deviceState", "Direct Connection")
                        put("signature", respSig)
                    }

                    val data = responseObj.toString().toByteArray(Charsets.UTF_8)
                    val value = if (offset < data.size) data.copyOfRange(offset, data.size) else ByteArray(0)
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                }
            })

            val service = BluetoothGattService(FINCELL_SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val char = BluetoothGattCharacteristic(
                FINCELL_TELEMETRY_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            service.addCharacteristic(char)
            gattServer?.addService(service)

            bleAdvertiser = btAdapter.bluetoothLeAdvertiser
            if (bleAdvertiser != null) {
                val settings = AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                    .setConnectable(true)
                    .build()

                val data = AdvertiseData.Builder()
                    .setIncludeDeviceName(false)
                    .addServiceUuid(ParcelUuid(FINCELL_SERVICE_UUID))
                    .build()

                bleAdvertiseCallback = object : AdvertiseCallback() {
                    override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                        Log.d("DIRECT_TRACE", "BLE Direct Advertiser started successfully")
                    }
                    override fun onStartFailure(errorCode: Int) {
                        Log.w("DIRECT_TRACE", "BLE Direct Advertiser failed with code: $errorCode")
                    }
                }
                bleAdvertiser?.startAdvertising(settings, data, bleAdvertiseCallback)
            }
        } catch (e: Exception) {
            Log.w("DIRECT_TRACE", "BLE Direct Responder setup skipped: ${e.message}")
        }
    }

    private fun stopDirectLocalTraceResponder() {
        try {
            directUdpSocket?.close()
            directUdpSocket = null
        } catch (_: Exception) {}

        try {
            directSocketThread?.interrupt()
            directSocketThread = null
        } catch (_: Exception) {}

        try {
            bleAdvertiseCallback?.let { bleAdvertiser?.stopAdvertising(it) }
            bleAdvertiser = null
            bleAdvertiseCallback = null
        } catch (_: Exception) {}

        try {
            gattServer?.clearServices()
            gattServer?.close()
            gattServer = null
        } catch (_: Exception) {}
    }
}
