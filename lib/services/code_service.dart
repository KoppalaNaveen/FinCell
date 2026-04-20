import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class CodeService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ================= RANDOM CODE =================
  static String _randomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    return List.generate(6, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  // ================= DELETE OLD CODE =================
  static Future<void> _deleteOldCode(String uid) async {
    try {
      final userDoc = await _db.collection('users').doc(uid).get();

      final oldCode = userDoc.data()?['uniqueCode'];

      if (oldCode != null) {
        await _db.collection('device_codes').doc(oldCode).delete();
        debugPrint("🧹 Old code removed: $oldCode");
      }
    } catch (e) {
      debugPrint("⚠️ Failed to delete old code: $e");
    }
  }

  // ================= SYSTEM GENERATED CODE =================
  static Future<String?> generateSystemCode(String deviceId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || deviceId.isEmpty) return null;

    final uid = user.uid;

    try {
      final userRef = _db.collection('users').doc(uid);

      final userDoc = await userRef.get();
      final oldCode = userDoc.data()?['uniqueCode'];

      if (oldCode != null) {
        await _db.collection('device_codes').doc(oldCode).delete();
      }

      for (int i = 0; i < 10; i++) {
        final code = _randomCode();
        final ref = _db.collection('device_codes').doc(code);

        await _db.runTransaction((tx) async {
          final doc = await tx.get(ref);

          if (doc.exists) throw Exception("Collision");

          tx.set(ref, {
            'ownerUid': uid,
            'deviceId': deviceId,
            'isLost': false,
            'createdAt': FieldValue.serverTimestamp(),
          });

          tx.set(userRef, {
            'uniqueCode': code,
          }, SetOptions(merge: true));
        });

        return code;
      }

      return null;

    } catch (e) {
      debugPrint("🔥 System code error: $e");
      return null;
    }
  }

  // ================= CUSTOM CODE =================
  static Future<String?> createCustomCode(String code, String deviceId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || deviceId.isEmpty) return null;

    final uid = user.uid;
    code = code.trim().toUpperCase();

    if (code.length < 6) return null;

    final ref = _db.collection('device_codes').doc(code);
    final userRef = _db.collection('users').doc(uid);

    try {
      final userDoc = await userRef.get();
      final oldCode = userDoc.data()?['uniqueCode'];

      if (oldCode != null) {
        await _db.collection('device_codes').doc(oldCode).delete();
      }

      await _db.runTransaction((tx) async {
        final doc = await tx.get(ref);

        if (doc.exists) {
          throw Exception("Code exists");
        }

        tx.set(ref, {
          'ownerUid': uid,
          'deviceId': deviceId,
          'isLost': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        tx.set(userRef, {
          'uniqueCode': code,
        }, SetOptions(merge: true));
      });

      return code;

    } catch (e) {
      debugPrint("🔥 Custom code error: $e");
      return null;
    }
  }

  // ================= TRACE DEVICE =================
  static Future<Map<String, dynamic>?> getDeviceByCode(String code) async {
    try {
      code = code.trim().toUpperCase();

      final doc = await _db.collection('device_codes').doc(code).get();

      if (!doc.exists) {
        debugPrint("❌ Code not found");
        return null;
      }

      return doc.data();
    } catch (e) {
      debugPrint("🔥 getDeviceByCode error: $e");
      return null;
    }
  }

  // ================= LOCATION UPDATE (OPTIONAL) =================
  static Future<void> updateDeviceLocation(
      String code, double lat, double lng) async {

    try {
      await _db.collection('device_codes').doc(code.toUpperCase()).update({
        'lastLocation': {
          'lat': lat,
          'lng': lng,
          'updatedAt': FieldValue.serverTimestamp(),
        }
      });
    } catch (e) {
      debugPrint("🔥 updateDeviceLocation error: $e");
    }
  }
}