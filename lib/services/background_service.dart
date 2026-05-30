import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

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

          debugPrint("Raw native location data: $args");

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

      final codeRef = FirebaseFirestore.instance
          .collection("device_codes")
          .doc(normalizedCode);

      final codeDoc = await codeRef.get();
      if (!codeDoc.exists) {
        debugPrint("Tracking start failed: code not found: $normalizedCode");
        return false;
      }

      await _updateTrackingStatus(normalizedCode, true);

      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
        );

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

  // ================= STATUS UPDATE =================
  static Future<void> _updateTrackingStatus(String code, bool isActive) async {
    try {
      await FirebaseFirestore.instance
          .collection('device_codes')
          .doc(code.toUpperCase())
          .set({
            'isLost': isActive,
            'lastUpdated': FieldValue.serverTimestamp(),
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
      if (accuracy != null && accuracy > 100) {
        debugPrint("Unusable low-accuracy fix ignored: $accuracy");
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastWriteTime < 3000) return;
      _lastWriteTime = now;

      final codeRef = FirebaseFirestore.instance
          .collection('device_codes')
          .doc(normalizedCode);

      if (_cachedOwnerUid == null ||
          _cachedDeviceId == null ||
          now - _lastCacheTime > 60000) {
        final doc = await codeRef.get();

        if (!doc.exists) {
          debugPrint("Code not found");
          return;
        }

        final data = doc.data();
        if (data == null) return;

        _cachedOwnerUid = data['ownerUid'];
        _cachedDeviceId = data['deviceId'];
        _cachedCode = normalizedCode;
        _lastCacheTime = now;

        debugPrint("Tracking mapping cached");
      }

      if (_cachedOwnerUid == null || _cachedDeviceId == null) {
        debugPrint("Mapping missing, skipping write");
        return;
      }

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

      await codeRef.set({
        'lastLocation': {
          'lat': lat,
          'lng': lng,
          'accuracy': accuracy,
          'battery': battery ?? 0,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint("Firestore location updated");
    } catch (e) {
      debugPrint("Firestore write failed: $e");
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
