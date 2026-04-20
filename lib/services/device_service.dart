import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';

class DeviceService {

  // 🔥 Generate fallback random ID
  static String _generateRandomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(24, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  // 🔥 Get or create stable deviceId
  static Future<String> _getStableDeviceId() async {
    final prefs = await SharedPreferences.getInstance();

    String? savedId = prefs.getString('device_id');

    if (savedId != null && savedId.isNotEmpty) {
      return savedId;
    }

    String deviceId;

    try {
      if (!kIsWeb) {
        final info = DeviceInfoPlugin();
        final android = await info.androidInfo;

        // 🔥 More stable combination
        deviceId =
            "${android.brand}_${android.model}_${android.device}_${android.id}";
      } else {
        deviceId = "web_${_generateRandomId()}";
      }
    } catch (e) {
      debugPrint("Device info error: $e");
      deviceId = _generateRandomId();
    }

    if (deviceId.isEmpty) {
      deviceId = _generateRandomId();
    }

    await prefs.setString('device_id', deviceId);

    return deviceId;
  }

  // ================= REGISTER DEVICE =================
  static Future<String> registerDevice() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw Exception("User not logged in");
    }

    final uid = user.uid;

    final deviceId = await _getStableDeviceId();

    debugPrint("🔥 FINAL DEVICE ID: $deviceId");

    String model = "Unknown Device";

    try {
      if (!kIsWeb) {
        final info = DeviceInfoPlugin();
        final android = await info.androidInfo;
        model = "${android.brand} ${android.model}";
      } else {
        model = "Web Browser";
      }
    } catch (e) {
      debugPrint("Model fetch error: $e");
    }

    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('devices')
        .doc(deviceId);

    try {
      // 🔥 Always use SET with merge → avoids update failures
      await ref.set({
        'ownerUid': uid,
        'deviceId': deviceId,
        'model': model,
        'isLost': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      return deviceId;

    } catch (e) {
      debugPrint("🔥 registerDevice FIRESTORE ERROR: $e");
      rethrow;
    }
  }
}