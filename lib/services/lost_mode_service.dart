import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class LostModeService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const MethodChannel _channel = MethodChannel(
    "fincell_service_channel",
  );

  // ================= SET LOST =================

  static Future<void> setLost(String deviceId, String code, bool isLost) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw Exception("User not logged in");
    }

    final uid = user.uid;

    code = code.trim().toUpperCase();

    debugPrint(
      "🔥 LOST MODE → code: $code, deviceId: $deviceId, isLost: $isLost",
    );

    try {
      // ================= STEP 1 — VALIDATE CODE =================

      final codeRef = _db.collection('device_codes').doc(code);
      final codeSnap = await codeRef.get();

      if (!codeSnap.exists) {
        throw Exception("Invalid code");
      }

      final data = codeSnap.data();

      if (data == null) {
        throw Exception("Invalid code data");
      }

      // ================= STEP 2 — OWNERSHIP =================

      if (data['ownerUid'] != uid) {
        throw Exception("You do not own this device");
      }

      // ================= STEP 3 — UPDATE GLOBAL =================

      await codeRef.set({
        'deviceId': deviceId,
        'isLost': isLost,
        'ownerUid': uid,
        'updatedAt': FieldValue.serverTimestamp(),

        // 🔥 ENSURE STRUCTURE EXISTS
        'lastLocation': data['lastLocation'] ?? null,
      }, SetOptions(merge: true));

      debugPrint("✅ device_codes updated");

      // ================= STEP 4 — UPDATE USER DEVICE =================

      await _db
          .collection('users')
          .doc(uid)
          .collection('devices')
          .doc(deviceId)
          .set({
            'isLost': isLost,
            'activeCode': code,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      debugPrint("✅ user device updated");

      // ================= STEP 5 — START / STOP SERVICE =================

      try {
        if (isLost) {
          debugPrint("🚀 Starting native tracking service");

          await _channel.invokeMethod("startService", {"code": code});
        } else {
          debugPrint("🛑 Stopping native tracking service");

          await _channel.invokeMethod("stopService");
        }
      } catch (e) {
        debugPrint("❌ Native service error: $e");

        // ❗ DO NOT crash app
      }
    } catch (e) {
      debugPrint("❌ LOST MODE ERROR: $e");

      throw Exception("Lost mode update failed: $e");
    }
  }
}
