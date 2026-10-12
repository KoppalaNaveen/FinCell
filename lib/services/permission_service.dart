import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';

class PermissionService {

  // ================= CAMERA =================

  static Future<bool> requestCamera() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  // ================= LOCATION (FIXED FLOW WITH PROMPTS) =================

  static Future<bool> requestLocationPermissionsProperly([
    BuildContext? context,
    bool requireBackground = false,
  ]) async {
    debugPrint("🔐 Checking location service & permissions...");

    await requestNotificationPermission();

    // STEP 1: CHECK IF GPS IS TURNED ON
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint("❌ GPS is OFF - prompting user to turn on location services");
      if (context != null && context.mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.location_off, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(child: Text("Turn On Location", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              ],
            ),
            content: const Text(
              "Location Services are currently turned OFF on your phone. Please turn ON Location Services so FinCell can perform live tracking & theft protection.",
              style: TextStyle(fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                },
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Geolocator.openLocationSettings();
                },
                child: const Text("Turn On Location", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      } else {
        await Geolocator.openLocationSettings();
      }
      return false;
    }

    // STEP 2: FOREGROUND LOCATION PERMISSION
    LocationPermission permission = await Geolocator.checkPermission();

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
      if (context != null && context.mounted) {
        await openAppSettings();
      }
      return false;
    }

    // STEP 3: BACKGROUND LOCATION PERMISSION ("ALLOW ALL THE TIME")
    if (permission == LocationPermission.whileInUse) {
      if (!requireBackground) {
        // Foreground permission is already sufficient for map & trace display
        Permission.locationAlways.request().catchError((_) => PermissionStatus.denied);
        return true;
      }

      debugPrint("⚠️ Requesting locationAlways permission...");
      var bgStatus = await Permission.locationAlways.request();

      if (!bgStatus.isGranted) {
        debugPrint("❌ Background permission (ALWAYS) not granted");
        if (context != null && context.mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.security, color: Colors.blue),
                  SizedBox(width: 8),
                  Expanded(child: Text("Allow Location All The Time", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                ],
              ),
              content: const Text(
                "Background Theft Protection requires location permission set to 'Allow all the time' in Settings so your phone can be traced if lost.",
                style: TextStyle(fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                  },
                  child: const Text("Later"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    openAppSettings();
                  },
                  child: const Text("Open Settings", style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
          return false;
        }
        // If context is null and whileInUse is granted, allow foreground tracking to continue
        return true;
      }
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

  static Future<void> requestDisableBatteryOptimization({bool openSettingsIfDenied = false}) async {
    if (!Platform.isAndroid) return;

    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) {
        debugPrint("🔋 Battery optimization already disabled");
        return;
      }

      if (!openSettingsIfDenied) {
        final prefs = await SharedPreferences.getInstance();
        final hasPrompted = prefs.getBool('battery_opt_prompted') ?? false;
        if (hasPrompted) return;
        await prefs.setBool('battery_opt_prompted', true);
      }

      final reqStatus = await Permission.ignoreBatteryOptimizations.request();
      if (!reqStatus.isGranted && openSettingsIfDenied) {
        final intent = AndroidIntent(
          action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
          data: 'package:com.example.fincell',
          flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        await intent.launch();
      }
      debugPrint("🔋 Battery optimization handled gracefully");
    } catch (e) {
      debugPrint("❌ Battery optimization request notice: $e");
    }
  }

  static Future<void> showOemBatteryOptimizationDialog(BuildContext context) async {
    if (!Platform.isAndroid || !context.mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.battery_alert, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                "Background Protection",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: const Text(
          "OEM Android devices (Samsung OneUI, Xiaomi MIUI, Realme UI, ColorOS, OxygenOS, FuntouchOS) aggressively stop background tracking services to save battery.\n\nTo ensure FinCell can continuously monitor and track your device if lost, please disable Battery Optimization or allow 'Unrestricted' background activity.",
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Later"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () {
              Navigator.pop(ctx);
              requestDisableBatteryOptimization(openSettingsIfDenied: true);
            },
            child: const Text("Open Settings", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ================= FULL SETUP =================

  static Future<bool> setupTrackingPermissions([BuildContext? context]) async {
    debugPrint("🚀 Setting up tracking permissions...");

    await requestNotificationPermission();
    if (context != null && !context.mounted) return false;
    bool locationOk = await requestLocationPermissionsProperly(context);

    await requestDisableBatteryOptimization();

    debugPrint("✅ All permissions checked");
    return locationOk;
  }
}