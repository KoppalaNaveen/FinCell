import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'offline_location_service.dart';
import 'offline_direct_trace_service.dart';
import 'sync_manager.dart';
import 'security_validator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackgroundTracking {
  static const MethodChannel _channel = MethodChannel(
    'fincell_service_channel',
  );

  static bool _listenerInitialized = false;

  static String? _cachedCode;
  static String? _cachedOwnerUid;
  static String? _cachedDeviceId;
  static int _lastWriteTime = 0;
  static int _lastCacheTime = 0;

  // ================= INIT LISTENER =================
  static void initializeNativeListener() {
    if (_listenerInitialized) return;

    _listenerInitialized = true;

    debugPrint("Initializing native tracking listener...");

    _channel.setMethodCallHandler((call) async {
      debugPrint("Native method called: ${call.method}");

      if (call.method == "onLocationUpdate") {
        try {
          final args = call.arguments;

          if (args == null) {
            debugPrint("Null args from native");
            return;
          }

          final String? code = args['code'];
          final double? lat = (args['lat'] as num?)?.toDouble();
          final double? lng = (args['lng'] as num?)?.toDouble();
          final double? accuracy = (args['accuracy'] as num?)?.toDouble();
          final int? battery = (args['battery'] as num?)?.toInt();

          final redactedCoords = SecurityValidator.redactCoordinates(lat, lng);
          final redactedCode = SecurityValidator.redactCode(code);
          debugPrint("Native location data received for $redactedCode: $redactedCoords");

          if (code == null || lat == null || lng == null) {
            debugPrint("Invalid location data");
            return;
          }

          await _sendLocationToFirestore(code, lat, lng, accuracy, battery);
        } catch (e) {
          debugPrint("Listener error: $e");
        }
      }
    });
  }

  // ================= START TRACKING =================
  static Future<bool> start(String code) async {
    if (kIsWeb) return false;

    final normalizedCode = code.trim().toUpperCase();
    if (normalizedCode.isEmpty) return false;

    try {
      _resetCacheIfCodeChanged(normalizedCode);

      _updateTrackingStatus(normalizedCode, true).catchError((e) {
        debugPrint("Background status update deferred: $e");
      });

      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
        ).timeout(const Duration(seconds: 3));

        await _sendLocationToFirestore(
          normalizedCode,
          position.latitude,
          position.longitude,
          position.accuracy,
          null,
        );
      } catch (e) {
        debugPrint("Immediate GPS fix skipped: $e");
      }

      final result = await _channel.invokeMethod('startService', {
        'code': normalizedCode,
      });

      debugPrint("Native tracking ensured: $result");
      return true;
    } catch (e) {
      debugPrint("Tracking start error: $e");
      return false;
    }
  }

  // ================= STOP TRACKING =================
  static Future<bool> stop(String code) async {
    if (kIsWeb) return false;

    try {
      final result = await _channel.invokeMethod('stopService');
      await _updateTrackingStatus(code, false);
      _resetCache();
      return result != null;
    } catch (e) {
      debugPrint("Stop service error: $e");
      return false;
    }
  }

  static Future<bool> stopLocalService() async {
    if (kIsWeb) return false;

    try {
      final result = await _channel.invokeMethod('stopService');
      _resetCache();
      debugPrint("Native foreground service stopped");
      return result != null;
    } catch (e) {
      debugPrint("Stop local service error: $e");
      return false;
    }
  }

  // ================= STATUS UPDATE =================
  static Future<void> _updateTrackingStatus(String code, bool isActive) async {
    try {
      await FirebaseFirestore.instance
          .collection('device_codes')
          .doc(code.toUpperCase())
          .set({
            'isOnline': isActive,
            'lastSeen': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Status update error: $e");
    }
  }

  // ================= LOCATION WRITE =================
  static Future<void> _sendLocationToFirestore(
    String code,
    double lat,
    double lng,
    double? accuracy,
    int? battery,
  ) async {
    try {
      final normalizedCode = code.trim().toUpperCase();
      _resetCacheIfCodeChanged(normalizedCode);

      debugPrint("Incoming location: $lat, $lng (accuracy: $accuracy)");

      if (!_isValidCoordinate(lat, lng)) {
        debugPrint("Invalid coordinate ignored");
        return;
      }

      // Keep slightly weak indoor fixes instead of freezing the map forever.
      if (accuracy != null && accuracy > 250) {
        debugPrint("Unusable low-accuracy fix ignored: $accuracy");
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastWriteTime < 1500) return;
      _lastWriteTime = now;

      // 1. Continuously save to Encrypted Local SQLite DB (Module 1 & 2)
      await OfflineLocationService.saveLocation(
        lat,
        lng,
        accuracy: accuracy ?? 0.0,
        battery: battery ?? 0,
      );

      final codeRef = FirebaseFirestore.instance
          .collection('device_codes')
          .doc(normalizedCode);

      // Always update device_codes doc immediately if online
      await codeRef.set({
        'latitude': lat,
        'longitude': lng,
        'timestamp': FieldValue.serverTimestamp(),
        'isOnline': true,
        'isLocationEnabled': true,
        'batteryLevel': battery ?? 0,
        'lastSeen': FieldValue.serverTimestamp(),
        'lastLocation': {
          'lat': lat,
          'lng': lng,
          'accuracy': accuracy,
          'battery': battery ?? 0,
          'updatedAt': FieldValue.serverTimestamp(),
          'uploadedAt': FieldValue.serverTimestamp(),
          'capturedAt': DateTime.now().toIso8601String(),
          'syncSource': 'live',
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (_cachedOwnerUid == null ||
          _cachedDeviceId == null ||
          now - _lastCacheTime > 60000) {
        try {
          final doc = await codeRef.get();
          if (doc.exists) {
            final data = doc.data();
            if (data != null) {
              _cachedOwnerUid = data['ownerUid'];
              _cachedDeviceId = data['deviceId'];
              _cachedCode = normalizedCode;
              _lastCacheTime = now;
            }
          }
        } catch (_) {}
      }

      if (_cachedOwnerUid != null && _cachedDeviceId != null) {
        final ownerUid = _cachedOwnerUid!;
        final deviceId = _cachedDeviceId!;

        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(ownerUid)
              .collection('devices')
              .doc(deviceId)
              .collection('locations')
              .add({
                'lat': lat,
                'lng': lng,
                'accuracy': accuracy,
                'battery': battery ?? 0,
                'timestamp': FieldValue.serverTimestamp(),
              });
        } catch (e) {
          debugPrint("History write failed: $e");
        }
      }

      debugPrint("Firestore location updated");
      SyncManager.instance.syncAll(normalizedCode);
    } catch (e) {
      debugPrint("Firestore write failed (queued in offline DB): $e");
      SyncManager.instance.syncAll(code.trim().toUpperCase());
    }
  }

  // ================= REMOTE COMMANDS =================
  static Future<void> sendPlaySoundCommand(String code, bool play) async {
    final normalizedCode = code.trim().toUpperCase();
    if (normalizedCode.isEmpty) return;

    // 1. If testing on the current device itself, trigger immediately
    try {
      final prefs = await SharedPreferences.getInstance();
      final localCode = prefs.getString('uniqueCode') ?? prefs.getString('device_code');
      if (localCode != null && localCode.trim().toUpperCase() == normalizedCode) {
        if (play) {
          await playAlarmSoundLocally(normalizedCode);
        } else {
          await stopAlarmSoundLocally(normalizedCode);
        }
      }
    } catch (_) {}

    // 2. Direct UDP dispatch to remote device on local network / hotspot
    try {
      await OfflineDirectTraceService.instance.sendDirectSoundCommand(normalizedCode, play);
    } catch (_) {}

    // 3. Firestore cloud command dispatch to remote lost device
    try {
      final payload = {
        'playSound': play,
        'stopSound': !play,
        'command': play ? 'alarm' : 'stop_alarm',
        'status': play ? 'playing' : 'stopped',
        'timestamp': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('device_commands')
          .doc(normalizedCode)
          .set(payload, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('device_codes')
          .doc(normalizedCode)
          .set({'playSound': play}, SetOptions(merge: true));

      debugPrint(
        "🔥 Device command sent to remote lost device: playSound=$play for code=$normalizedCode",
      );
    } catch (e) {
      debugPrint("🔥 Command send error: $e");
    }
  }

  static Future<void> playLocalNotificationSound() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('playNotificationSound');
    } catch (e) {
      debugPrint("Local notification sound error: $e");
    }
  }

  static Future<void> playAlarmSoundLocally([String? code]) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('startAlarm', {'code': code ?? ''});
    } catch (e) {
      debugPrint("Local startAlarm error: $e");
    }
  }

  static Future<void> stopAlarmSoundLocally([String? code]) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('stopAlarm', {'code': code ?? ''});
    } catch (e) {
      debugPrint("Local stopAlarm error: $e");
    }
  }

  static bool _isValidCoordinate(double lat, double lng) {
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  static void _resetCacheIfCodeChanged(String code) {
    if (_cachedCode == code) return;
    _resetCache();
  }

  static void _resetCache() {
    _cachedCode = null;
    _cachedOwnerUid = null;
    _cachedDeviceId = null;
    _lastCacheTime = 0;
    _lastWriteTime = 0;
  }

  // ================= BATTERY OPT =================
  static Future<void> requestBatteryOptimization() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('requestBatteryOptimization');
    } catch (e) {
      debugPrint("Battery optimization error: $e");
    }
  }

  // ================= STEALTH MODE =================
  static Future<void> hideApp() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('hideApp');
    } catch (e) {
      debugPrint("Hide app error: $e");
    }
  }

  static Future<void> showApp() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('showApp');
    } catch (e) {
      debugPrint("Show app error: $e");
    }
  }
}
