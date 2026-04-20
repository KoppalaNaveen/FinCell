import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/foundation.dart';

class PermissionService {

  // ================= CAMERA =================

  static Future<bool> requestCamera() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  // ================= LOCATION (FIXED FLOW) =================

  static Future<bool> requestLocationPermissionsProperly() async {

    debugPrint("🔐 Checking location service...");

    // STEP 1: GPS ON/OFF
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      debugPrint("❌ GPS OFF");
      await Geolocator.openLocationSettings();
      return false;
    }

    // STEP 2: FOREGROUND PERMISSION
    LocationPermission permission =
        await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      debugPrint("➡️ Requesting foreground permission...");
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      debugPrint("❌ Foreground denied");
      return false;
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint("❌ Permanently denied → open settings");
      await openAppSettings();
      return false;
    }

    // STEP 3: BACKGROUND PERMISSION (REAL FIX)
    if (permission == LocationPermission.whileInUse) {

      debugPrint("⚠️ Only WHILE_IN_USE granted");

      // Use permission_handler for background
      var bgStatus = await Permission.locationAlways.request();

      if (!bgStatus.isGranted) {
        debugPrint("❌ Background (ALWAYS) NOT granted");

        // Force user to settings
        await openAppSettings();
        return false;
      }

      debugPrint("✅ Background permission granted");
    }

    if (permission == LocationPermission.always) {
      debugPrint("✅ Already has ALWAYS permission");
    }

    return true;
  }

  // ================= NOTIFICATION (ANDROID 13+) =================

  static Future<bool> requestNotificationPermission() async {

    if (!Platform.isAndroid) return true;

    final status = await Permission.notification.request();

    if (!status.isGranted) {
      debugPrint("❌ Notification permission denied");
      return false;
    }

    debugPrint("✅ Notification permission granted");

    return true;
  }

  // ================= SETTINGS =================

  static Future<void> openAppSettingsManual() async {
    await openAppSettings();
  }

  static Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  // ================= BATTERY OPTIMIZATION =================

  static Future<void> requestDisableBatteryOptimization() async {

    if (!Platform.isAndroid) return;

    try {

      final intent = AndroidIntent(
        action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
        data: 'package:com.example.fincell',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );

      await intent.launch();

      debugPrint("🔋 Requested battery optimization disable");

    } catch (e) {
      debugPrint("❌ Battery optimization request failed: $e");
    }
  }

  // ================= FULL SETUP =================

  static Future<bool> setupTrackingPermissions() async {

    debugPrint("🚀 Setting up tracking permissions...");

    bool locationOk = await requestLocationPermissionsProperly();

    if (!locationOk) return false;

    bool notificationOk = await requestNotificationPermission();

    if (!notificationOk) return false;

    await requestDisableBatteryOptimization();

    debugPrint("✅ All permissions ready");

    return true;
  }
}