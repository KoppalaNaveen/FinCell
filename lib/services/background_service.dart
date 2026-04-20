import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BackgroundTracking {
  static const MethodChannel _channel =
      MethodChannel('fincell_service_channel');

  static bool _listenerInitialized = false;

  // 🔥 CACHE (CRITICAL FIX)
  static String? _cachedOwnerUid;
  static String? _cachedDeviceId;

  // ================= INIT LISTENER =================
  static void initializeNativeListener() {
    if (_listenerInitialized) return;

    _listenerInitialized = true;

    debugPrint("🚀 Initializing Native Listener...");

    _channel.setMethodCallHandler((call) async {
      debugPrint("🔥 METHOD CALLED: ${call.method}");

      if (call.method == "onLocationUpdate") {
        try {
          final args = call.arguments;

          if (args == null) {
            debugPrint("❌ Null args from native");
            return;
          }

          final String? code = args['code'];
          final double? lat = (args['lat'] as num?)?.toDouble();
          final double? lng = (args['lng'] as num?)?.toDouble();
          final double? accuracy = (args['accuracy'] as num?)?.toDouble();
          final int? battery = (args['battery'] as num?)?.toInt();

          debugPrint("📡 RAW DATA → $args");

          if (code == null || lat == null || lng == null) {
            debugPrint("❌ Invalid location data");
            return;
          }

          await _sendLocationToFirestore(
            code,
            lat,
            lng,
            accuracy,
            battery,
          );

          debugPrint("✅ LOCATION PROCESSED");

        } catch (e) {
          debugPrint("🔥 Listener error: $e");
        }
      }
    });

    debugPrint("✅ Native listener initialized");
  }

  // ================= START TRACKING =================
  static Future<bool> start(String code) async {
    if (kIsWeb) return false;

    if (code.isEmpty) {
      debugPrint("❌ Invalid tracking code");
      return false;
    }

    try {
      initializeNativeListener();

      final upperCode = code.toUpperCase();

      final bool result = await _channel.invokeMethod('startService', {
        "code": upperCode,
      });

      if (result) {
        debugPrint("✅ Service started for code: $upperCode");

        // 🔥 RESET CACHE WHEN NEW SESSION STARTS
        _cachedOwnerUid = null;
        _cachedDeviceId = null;

        await _updateTrackingStatus(upperCode, true);
      }

      return result;
    } catch (e) {
      debugPrint("🔥 Start service error: $e");
      return false;
    }
  }

  // ================= STOP TRACKING =================
  static Future<bool> stop(String code) async {
    if (kIsWeb) return false;

    try {
      final bool result = await _channel.invokeMethod('stopService');

      if (result) {
        await _updateTrackingStatus(code, false);
      }

      return result;
    } catch (e) {
      debugPrint("🔥 Stop service error: $e");
      return false;
    }
  }

  // ================= STATUS UPDATE =================
  static Future<void> _updateTrackingStatus(
      String code, bool isActive) async {
    try {
      await FirebaseFirestore.instance
          .collection('device_codes')
          .doc(code.toUpperCase())
          .update({
        'isLost': isActive,
        'lastUpdated': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("🔥 Status update error: $e");
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
      debugPrint("📍 Writing location → $lat, $lng");

      final codeRef = FirebaseFirestore.instance
          .collection('device_codes')
          .doc(code.toUpperCase());

      // 🔥 FETCH ONLY ONCE (CACHE)
      if (_cachedOwnerUid == null || _cachedDeviceId == null) {
        final doc = await codeRef.get();

        if (!doc.exists) {
          debugPrint("❌ Code not found");
          return;
        }

        final data = doc.data();
        if (data == null) return;

        _cachedOwnerUid = data['ownerUid'];
        _cachedDeviceId = data['deviceId'];

        debugPrint("✅ Mapping cached");
      }

      final ownerUid = _cachedOwnerUid!;
      final deviceId = _cachedDeviceId!;

      debugPrint("📡 Using cached UID: $ownerUid, deviceId: $deviceId");

      // 🔥 WRITE HISTORY
      await FirebaseFirestore.instance
          .collection('users')
          .doc(ownerUid)
          .collection('devices')
          .doc(deviceId)
          .collection('locations')
          .add({
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy ?? 0,
        'battery': battery ?? -1,
        'timestamp': FieldValue.serverTimestamp(),
      });

      // 🔥 UPDATE LIVE LOCATION
      await codeRef.set({
        'lastLocation': {
          'lat': lat,
          'lng': lng,
          'accuracy': accuracy ?? 0,
          'battery': battery ?? -1,
          'updatedAt': FieldValue.serverTimestamp(),
        }
      }, SetOptions(merge: true));

      debugPrint("✅ FIRESTORE UPDATED SUCCESSFULLY");

    } catch (e) {
      debugPrint("🔥 Firestore write failed: $e");
    }
  }

  // ================= BATTERY OPT =================
  static Future<void> requestBatteryOptimization() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('requestBatteryOptimization');
    } catch (e) {
      debugPrint("🔥 Battery optimization error: $e");
    }
  }

  // ================= STEALTH MODE =================
  static Future<void> hideApp() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('hideApp');
    } catch (e) {
      debugPrint("🔥 Hide app error: $e");
    }
  }

  static Future<void> showApp() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('showApp');
    } catch (e) {
      debugPrint("🔥 Show app error: $e");
    }
  }
}