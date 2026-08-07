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
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.SetOptions
import com.google.firebase.storage.FirebaseStorage
import java.io.File

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

    private var mediaPlayer: MediaPlayer? = null
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

        var code = intent?.getStringExtra("code")?.uppercase()

        if (code.isNullOrEmpty()) {
            val prefs = getSharedPreferences("fincell_prefs", Context.MODE_PRIVATE)
            code = prefs.getString("device_code", null)?.uppercase()
        }

        if (code.isNullOrEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, createNotification())

        checkAndNotifyLocationState()

        if (!hasLocationPermission()) {
            stopSelf()
            return START_NOT_STICKY
        }

        startLocationUpdates(code)
        listenForCommands(code)
        startCameraCaptureTimer(code)

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
        try {
            val gpsEnabled = isGpsEnabled()
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            if (!gpsEnabled) {
                createLocationAlertChannel(nm)

                val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pendingIntent = PendingIntent.getActivity(
                    this,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                val builder = NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.ic_dialog_alert)
                    .setContentTitle("⚠️ Location Services Disabled")
                    .setContentText("Location is turned OFF on your phone. Tap to turn ON GPS for live tracking & theft protection.")
                    .setStyle(NotificationCompat.BigTextStyle().bigText("Location is turned OFF on your phone. Tap here to turn ON GPS so FinCell can perform live tracking & theft protection."))
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setCategory(NotificationCompat.CATEGORY_ALARM)
                    .setOngoing(true)
                    .setAutoCancel(false)
                    .setContentIntent(pendingIntent)

                nm.notify(LOCATION_OFF_NOTIFICATION_ID, builder.build())
                scheduleLocationReminderAlarm()
            } else {
                nm.cancel(LOCATION_OFF_NOTIFICATION_ID)
                cancelLocationReminderAlarm()
            }
        } catch (e: Exception) {
            Log.e("LOCATION_ALERT", "Error checking location state: ${e.message}")
        }
    }

    private fun scheduleLocationReminderAlarm() {
        try {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(this, LocationForegroundService::class.java).apply {
                action = "CHECK_LOCATION_REMINDER"
            }
            val pendingIntent = PendingIntent.getService(
                this,
                998,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val intervalMs = 30 * 60 * 1000L // 30 minutes
            alarmManager.setRepeating(
                AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + intervalMs,
                intervalMs,
                pendingIntent
            )
        } catch (e: Exception) {
            Log.e("LOCATION_REMINDER", "Error scheduling reminder alarm", e)
        }
    }

    private fun cancelLocationReminderAlarm() {
        try {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(this, LocationForegroundService::class.java).apply {
                action = "CHECK_LOCATION_REMINDER"
            }
            val pendingIntent = PendingIntent.getService(
                this,
                998,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.cancel(pendingIntent)
        } catch (e: Exception) {
            Log.e("LOCATION_REMINDER", "Error cancelling reminder alarm", e)
        }
    }

    private fun createLocationAlertChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                ALERT_CHANNEL_ID,
                "Location Alert Notifications",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifies user when GPS/Location services are turned off"
                enableVibration(true)
            }
            nm.createNotificationChannel(channel)
        }
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

        val riskData = hashMapOf<String, Any>(
            "riskScore" to riskScore,
            "riskFactors" to factors,
            "theftStatus" to if (riskScore >= 50) "Possible Theft Detected" else "Normal",
            "lastRiskUpdate" to Timestamp.now()
        )
        db.collection("device_codes")
            .document(code)
            .set(riskData, SetOptions.merge())

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

        // Native snapshot listener for remote lost mode triggers
        codeStatusListener?.remove()
        codeStatusListener = db.collection("device_codes")
            .document(code)
            .addSnapshotListener { snapshot, error ->
                if (error != null || snapshot == null || !snapshot.exists()) return@addSnapshotListener
                val owner = snapshot.getString("ownerUid")
                val device = snapshot.getString("deviceId")
                val isLost = snapshot.getBoolean("isLost") ?: false
                val traceRequestedAt = snapshot.getTimestamp("traceRequestedAt")

                if (!owner.isNullOrEmpty()) cachedOwnerUid = owner
                if (!device.isNullOrEmpty()) cachedDeviceId = device

                if (isLost || traceRequestedAt != null) {
                    fetchAndPushImmediateLocation(code)
                }
            }

        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            2000L
        )
            .setMinUpdateIntervalMillis(1000L)
            .setMinUpdateDistanceMeters(0f)
            .setWaitForAccurateLocation(false)
            .build()

        locationCallback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val location = result.lastLocation ?: return

                val lat = location.latitude
                val lng = location.longitude
                val accuracy = location.accuracy
                val battery = getBatteryLevel()
                val speed = location.speed.toDouble()
                val heading = location.bearing.toDouble()

                // Allow up to 500m initial fixes so updates aren't frozen on startup
                if (accuracy > 500) return

                val now = System.currentTimeMillis()
                val prev = lastLocation
                if (prev != null) {
                    val distanceMoved = prev.distanceTo(location)
                    if (distanceMoved < 0.5f && (now - lastUpdateTime < 3000)) {
                        return
                    }
                }

                if (now - lastUpdateTime < 1000) return
                lastUpdateTime = now
                lastLocation = location

                // Always write location to device_codes/{code} directly
                writeLocation(code, lat, lng, accuracy, battery, speed, heading)

                // Fetch ownerUid and deviceId in background if not yet cached
                if (cachedDeviceId == null || cachedOwnerUid == null || now - lastCacheTime > 60000) {
                    db.collection("device_codes")
                        .document(code)
                        .get()
                        .addOnSuccessListener { doc ->
                            if (doc.exists()) {
                                cachedDeviceId = doc.getString("deviceId")
                                cachedOwnerUid = doc.getString("ownerUid")
                                cachedCode = code
                                lastCacheTime = System.currentTimeMillis()
                            }
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

        val updateData = hashMapOf<String, Any>(
            "latitude" to lat,
            "longitude" to lng,
            "timestamp" to now,
            "isOnline" to true,
            "isLocationEnabled" to gpsEnabled,
            "batteryLevel" to battery,
            "speed" to speed,
            "heading" to heading,
            "lastSeen" to now,
            "lastLocation" to hashMapOf(
                "lat" to lat,
                "lng" to lng,
                "accuracy" to accuracy,
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

        if (deviceId != null && ownerUid != null) {
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

    // ================= COMMAND LISTENER & REMOTE ACTIONS =================

    private fun listenForCommands(code: String) {
        commandListener?.remove()
        commandListener = db.collection("device_commands")
            .document(code)
            .addSnapshotListener { snapshot, error ->
                if (error != null || snapshot == null || !snapshot.exists()) return@addSnapshotListener

                val playSound = snapshot.getBoolean("playSound") == true
                val stopSound = snapshot.getBoolean("stopSound") == true
                val command = snapshot.getString("command") ?: ""
                val status = snapshot.getString("status") ?: ""

                Log.d("ALARM", "Command snapshot: playSound=$playSound, stopSound=$stopSound, command=$command, status=$status")

                if (stopSound || command == "stop_alarm" || (status == "stopped" && (mediaPlayer != null || toneGenerator != null))) {
                    stopAlarm(code)
                } else if ((playSound || command == "alarm") && status != "playing") {
                    startAlarm(code)
                }

                // Handle Additional Remote Commands
                if (status == "pending" && command.isNotEmpty()) {
                    val requestId = snapshot.getString("requestId") ?: ""
                    val requestedBy = snapshot.getString("requestedBy") ?: ""

                    // Mark running
                    db.collection("device_commands")
                        .document(code)
                        .set(hashMapOf("status" to "running"), SetOptions.merge())

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
    }

    // ================= ALARM MANAGEMENT =================

    private fun startAlarm(code: String) {
        try {
            Log.d("ALARM", "startAlarm called for code: $code")

            // 1. Un-mute & Maximise All Audio Streams
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            try {
                audioManager.ringerMode = AudioManager.RINGER_MODE_NORMAL
                val streams = intArrayOf(
                    AudioManager.STREAM_ALARM,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.STREAM_RING,
                    AudioManager.STREAM_NOTIFICATION
                )
                for (stream in streams) {
                    val maxVol = audioManager.getStreamMaxVolume(stream)
                    audioManager.setStreamVolume(stream, maxVol, 0)
                }
            } catch (e: Exception) {
                Log.w("ALARM", "Could not override volume/ringer mode: ${e.message}")
            }

            if (mediaPlayer == null && toneGenerator == null) {
                val urisToTry = arrayOf(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    Settings.System.DEFAULT_ALARM_ALERT_URI,
                    Settings.System.DEFAULT_RINGTONE_URI,
                    Settings.System.DEFAULT_NOTIFICATION_URI
                )

                var playedSuccessfully = false

                for (uri in urisToTry) {
                    if (uri == null) continue
                    try {
                        val player = MediaPlayer().apply {
                            setDataSource(applicationContext, uri)
                            setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_ALARM)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                    .build()
                            )
                            isLooping = true
                            prepare()
                            start()
                        }
                        mediaPlayer = player
                        playedSuccessfully = true
                        Log.d("ALARM", "Playing alarm audio successfully from URI: $uri")
                        break
                    } catch (e: Exception) {
                        Log.w("ALARM", "Failed to play URI $uri: ${e.message}")
                    }
                }

                // If all MediaPlayer URIs fail, fallback to ToneGenerator siren
                if (!playedSuccessfully) {
                    Log.d("ALARM", "Falling back to ToneGenerator siren")
                    startToneGeneratorSiren()
                }
            }

            val cmdData = hashMapOf<String, Any>(
                "playSound" to true,
                "stopSound" to false,
                "command" to "alarm",
                "status" to "playing",
                "timestamp" to Timestamp.now()
            )
            db.collection("device_commands")
                .document(code)
                .set(cmdData, SetOptions.merge())

            alarmTimeoutHandler?.removeCallbacksAndMessages(null)
            alarmTimeoutHandler = Handler(Looper.getMainLooper())
            alarmTimeoutHandler?.postDelayed({ stopAlarm(code) }, 120000L)

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
                        val tone = if (toggle) ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK else ToneGenerator.TONE_CDMA_HIGH_L
                        toneGenerator?.startTone(tone, 400)
                        toggle = !toggle
                    } catch (e: Exception) {
                        Log.e("ALARM", "ToneGenerator error: ${e.message}")
                    }
                }
            }, 0L, 500L)
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

            mediaPlayer?.let { mp ->
                try {
                    mp.stop()
                } catch (_: Exception) {}
                try {
                    mp.reset()
                } catch (_: Exception) {}
                try {
                    mp.release()
                } catch (_: Exception) {}
            }
            mediaPlayer = null

            stopToneGeneratorSiren()

            if (!code.isNullOrEmpty()) {
                val stopData = hashMapOf<String, Any>(
                    "playSound" to false,
                    "stopSound" to true,
                    "command" to "stop_alarm",
                    "status" to "stopped",
                    "timestamp" to Timestamp.now()
                )
                db.collection("device_commands")
                    .document(code)
                    .set(stopData, SetOptions.merge())
            }
        } catch (e: Exception) {
            Log.e("ALARM", "Error stopping alarm: ${e.message}")
        }
    }

    // ================= CAMERAX 5-MIN TIMER CAPTURE =================

    private fun startCameraCaptureTimer(code: String) {
        cameraTimerHandler?.removeCallbacksAndMessages(null)
        cameraTimerHandler = Handler(Looper.getMainLooper())

        val timerRunnable = object : Runnable {
            override fun run() {
                silentCameraManager?.captureFrontCamera(
                    deviceCode = code,
                    reason = "5-Minute Lost Mode Auto Capture",
                    lat = lastLocation?.latitude,
                    lng = lastLocation?.longitude,
                    battery = getBatteryLevel()
                )
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
            val now = Timestamp.now()
            val storageRef = FirebaseStorage.getInstance().reference.child("lost_audio/$code/${System.currentTimeMillis()}.mp3")

            storageRef.putFile(Uri.fromFile(file))
                .addOnSuccessListener {
                    storageRef.downloadUrl.addOnSuccessListener { uri ->
                        val recordData = hashMapOf<String, Any>(
                            "audioUrl" to uri.toString(),
                            "timestamp" to now,
                            "latitude" to (lastLocation?.latitude ?: 0.0),
                            "longitude" to (lastLocation?.longitude ?: 0.0),
                            "battery" to getBatteryLevel(),
                            "duration" to 30,
                            "fileSize" to fileSize,
                            "commandId" to commandId,
                            "recordedByDevice" to requestedBy
                        )

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

                        try { file.delete() } catch (_: Exception) {}
                    }
                }
                .addOnFailureListener { e ->
                    Log.e("AUDIO_REC", "Audio upload failed: ${e.message}")
                    markCommandFailed(code, "Audio upload failed: ${e.message}")
                }
        } catch (e: Exception) {
            Log.e("AUDIO_REC", "Error stopping/uploading audio: ${e.message}")
            markCommandFailed(code, "Audio processing failed: ${e.message}")
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
                    }
                }
            }
            cm.registerNetworkCallback(request, connectivityCallback!!)
        } catch (_: Exception) {}
    }

    private fun isGpsEnabled(): Boolean {
        val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    private fun getBatteryLevel(): Int {
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        return if (level >= 0 && scale > 0) level * 100 / scale else 0
    }

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FinCell::TrackingWakeLock")
        wakeLock.acquire(10 * 60 * 1000L)
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
        locationCallback?.let { fusedClient.removeLocationUpdates(it) }
        commandListener?.remove()
        commandListener = null
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
        super.onDestroy()
    }
}
