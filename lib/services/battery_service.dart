import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

class BatteryService {
  static final Battery _battery = Battery();
  static int _cachedLevel = -1;
  static int _lastFetchTime = 0;

  /// Returns the current battery percentage (0–100).
  /// Caches the result for 10 seconds to avoid excessive native calls.
  /// Returns -1 if battery level cannot be determined.
  static Future<int> getBatteryLevel() async {
    if (kIsWeb) return -1;

    final now = DateTime.now().millisecondsSinceEpoch;
    // Return cached value if fetched within the last 10 seconds
    if (_cachedLevel >= 0 && (now - _lastFetchTime) < 10000) {
      return _cachedLevel;
    }

    try {
      final level = await _battery.batteryLevel;
      _cachedLevel = level;
      _lastFetchTime = now;
      return level;
    } catch (e) {
      debugPrint("Battery level read failed: $e");
      return _cachedLevel >= 0 ? _cachedLevel : -1;
    }
  }
}
