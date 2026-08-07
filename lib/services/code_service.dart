import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CodeResult {
  final bool success;
  final String? code;
  final String message;

  CodeResult({required this.success, this.code, required this.message});
}

class CodeService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static bool isValidFormat(String code) {
    final cleanCode = code.trim().toUpperCase();
    final regex = RegExp(r'^[A-Z0-9]{6,8}$');
    return regex.hasMatch(cleanCode);
  }

  // ================= RANDOM CODE =================
  static String _randomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    return List.generate(6, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  static String? _readExistingCode(Map<String, dynamic>? data) {
    final rawCode = data?['uniqueCode'] ?? data?['deviceCode'];
    if (rawCode == null) return null;

    final code = rawCode.toString().trim().toUpperCase();
    return code.isEmpty ? null : code;
  }

  static Map<String, dynamic> _userCodeData(String code) {
    return {
      'uniqueCode': code,
      'deviceCode': code,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Map<String, dynamic> _deviceCodeData({
    required String uid,
    required String deviceId,
    required String code,
    required bool includeCreatedAt,
    Position? initialPosition,
  }) {
    final data = <String, dynamic>{
      'ownerUid': uid,
      'deviceId': deviceId,
      'deviceCode': code,
      'isLost': false,
      'isOnline': true,
      'isLocationEnabled': true,
      'lastSeen': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (includeCreatedAt) {
      data['createdAt'] = FieldValue.serverTimestamp();
    }

    if (initialPosition != null) {
      data['latitude'] = initialPosition.latitude;
      data['longitude'] = initialPosition.longitude;
      data['speed'] = initialPosition.speed;
      data['heading'] = initialPosition.heading;
      data['batteryLevel'] = 100;
      data['lastLocation'] = {
        'lat': initialPosition.latitude,
        'lng': initialPosition.longitude,
        'accuracy': initialPosition.accuracy,
        'speed': initialPosition.speed,
        'heading': initialPosition.heading,
        'updatedAt': FieldValue.serverTimestamp(),
      };
    }

    return data;
  }

  static Future<Position?> _loadInitialPositionForCode() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      ).timeout(const Duration(seconds: 3));
      debugPrint(
        "Initial Location Loaded: ${position.latitude}, ${position.longitude}",
      );
      return position;
    } catch (e, stackTrace) {
      debugPrint("Initial Location Skipped: $e");
      debugPrint("Stack Trace: $stackTrace");
      return null;
    }
  }

  static String _errorDetails(Object error) {
    if (error is FirebaseException) {
      return "${error.plugin}/${error.code}: ${error.message ?? error.toString()}";
    }
    return error.toString();
  }

  static Future<bool> _cacheCode({
    required SharedPreferences prefs,
    required String uid,
    required String code,
  }) async {
    try {
      final savedUnique = await prefs.setString('uniqueCode', code);
      final savedUid = await prefs.setString('cached_code_$uid', code);

      debugPrint(
        "SharedPreferences Saved: uniqueCode=$savedUnique cached_code_$uid=$savedUid",
      );

      return savedUnique && savedUid;
    } catch (e, stackTrace) {
      debugPrint("SharedPreferences Save Failed: $e");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  // ================= SYSTEM GENERATED CODE =================
  static Future<CodeResult> generateSystemCode(String deviceId) async {
    debugPrint("Create Device Code: started");

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || deviceId.isEmpty) {
      debugPrint(
        "Create Device Code Failed: user=${user?.uid}, deviceId=$deviceId",
      );
      return CodeResult(success: false, message: "User not logged in");
    }

    final uid = user.uid;
    debugPrint("Current UID: $uid");
    debugPrint("Device ID: $deviceId");

    try {
      final prefs = await SharedPreferences.getInstance();
      final userRef = _db.collection('users').doc(uid);
      final initialPosition = await _loadInitialPositionForCode();

      final code = await _db.runTransaction<String>((transaction) async {
        debugPrint("Checking existing code at users/$uid");

        final userDoc = await transaction.get(userRef);
        final existingCode = _readExistingCode(userDoc.data());

        if (existingCode != null) {
          debugPrint("Existing Device Code Found: $existingCode");

          final existingCodeRef = _db
              .collection('device_codes')
              .doc(existingCode);
          final existingCodeDoc = await transaction.get(existingCodeRef);
          final existingCodeData = existingCodeDoc.data();
          final ownerUid = existingCodeData?['ownerUid']?.toString();

          if (existingCodeDoc.exists &&
              ownerUid != null &&
              ownerUid.isNotEmpty &&
              ownerUid != uid) {
            throw StateError(
              "Existing code $existingCode belongs to another UID: $ownerUid",
            );
          }

          if (!existingCodeDoc.exists) {
            debugPrint(
              "Existing user code missing device_codes/$existingCode; recreating",
            );
          }

          transaction.set(
            existingCodeRef,
            _deviceCodeData(
              uid: uid,
              deviceId: deviceId,
              code: existingCode,
              includeCreatedAt: !existingCodeDoc.exists,
              initialPosition: initialPosition,
            ),
            SetOptions(merge: true),
          );
          transaction.set(
            userRef,
            _userCodeData(existingCode),
            SetOptions(merge: true),
          );

          return existingCode;
        }

        for (int i = 0; i < 20; i++) {
          final generatedCode = _randomCode();
          debugPrint("Generated Code: $generatedCode");

          final codeRef = _db.collection('device_codes').doc(generatedCode);
          final codeDoc = await transaction.get(codeRef);

          if (codeDoc.exists) {
            debugPrint("Duplicate Code Detected: $generatedCode");
            continue;
          }

          debugPrint(
            "Saving Firestore transaction: users/$uid and device_codes/$generatedCode",
          );

          transaction.set(
            codeRef,
            _deviceCodeData(
              uid: uid,
              deviceId: deviceId,
              code: generatedCode,
              includeCreatedAt: true,
              initialPosition: initialPosition,
            ),
          );
          transaction.set(
            userRef,
            _userCodeData(generatedCode),
            SetOptions(merge: true),
          );

          return generatedCode;
        }

        throw StateError(
          "Failed to generate a unique device code after 20 attempts",
        );
      });

      debugPrint("Firestore Write Success: users/$uid device_codes/$code");

      final cached = await _cacheCode(prefs: prefs, uid: uid, code: code);
      if (!cached) {
        return CodeResult(
          success: false,
          message: "Code saved in Firestore but local cache save failed.",
        );
      }

      return CodeResult(
        success: true,
        code: code,
        message: "Code created successfully",
      );
    } catch (e, stackTrace) {
      debugPrint("Firestore Write Failed: ${_errorDetails(e)}");
      debugPrint("Exception: $e");
      debugPrint("Stack Trace: $stackTrace");

      return CodeResult(
        success: false,
        message: "Code creation failed: ${_errorDetails(e)}",
      );
    }
  }

  // ================= CUSTOM CODE =================
  static Future<CodeResult> createCustomCode(
    String inputCode,
    String deviceId,
  ) async {
    debugPrint("Custom Device Code Creation: started");

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || deviceId.isEmpty) {
      debugPrint(
        "Custom Device Code Failed: user=${user?.uid}, deviceId=$deviceId",
      );
      return CodeResult(success: false, message: "User not logged in");
    }

    final uid = user.uid;
    final code = inputCode.trim().toUpperCase();
    debugPrint("Current UID: $uid");
    debugPrint("Requested Custom Code: $code");

    if (!isValidFormat(code)) {
      return CodeResult(
        success: false,
        message:
            "Code must be 6 to 8 characters long (letters & numbers only).",
      );
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final ref = _db.collection('device_codes').doc(code);
      final userRef = _db.collection('users').doc(uid);
      final initialPosition = await _loadInitialPositionForCode();

      final savedCode = await _db.runTransaction<String>((transaction) async {
        debugPrint("Checking requested code at device_codes/$code");

        final userDoc = await transaction.get(userRef);
        final existingDoc = await transaction.get(ref);
        final existingData = existingDoc.data();
        final ownerUid = existingData?['ownerUid']?.toString();

        if (existingDoc.exists &&
            ownerUid != null &&
            ownerUid.isNotEmpty &&
            ownerUid != uid) {
          throw StateError("This code is already taken by another user.");
        }

        final oldCode = _readExistingCode(userDoc.data());
        DocumentReference<Map<String, dynamic>>? oldCodeRef;
        DocumentSnapshot<Map<String, dynamic>>? oldCodeDoc;

        if (oldCode != null && oldCode != code) {
          oldCodeRef = _db.collection('device_codes').doc(oldCode);
          oldCodeDoc = await transaction.get(oldCodeRef);
          debugPrint("Old Device Code Found: $oldCode");
        }

        if (oldCodeRef != null && oldCodeDoc != null && oldCodeDoc.exists) {
          debugPrint("Deleting Old Device Code: device_codes/$oldCode");
          transaction.delete(oldCodeRef);
        }

        debugPrint(
          "Saving Firestore transaction: users/$uid and device_codes/$code",
        );

        transaction.set(
          ref,
          _deviceCodeData(
            uid: uid,
            deviceId: deviceId,
            code: code,
            includeCreatedAt: !existingDoc.exists,
            initialPosition: initialPosition,
          ),
          SetOptions(merge: true),
        );
        transaction.set(userRef, _userCodeData(code), SetOptions(merge: true));

        return code;
      });

      debugPrint("Firestore Write Success: users/$uid device_codes/$savedCode");

      final cached = await _cacheCode(prefs: prefs, uid: uid, code: savedCode);
      if (!cached) {
        return CodeResult(
          success: false,
          message: "Code saved in Firestore but local cache save failed.",
        );
      }

      return CodeResult(
        success: true,
        code: savedCode,
        message: "Code created successfully",
      );
    } catch (e, stackTrace) {
      debugPrint("Firestore Write Failed: ${_errorDetails(e)}");
      debugPrint("Exception: $e");
      debugPrint("Stack Trace: $stackTrace");

      return CodeResult(
        success: false,
        message: "Code creation failed: ${_errorDetails(e)}",
      );
    }
  }

  // ================= TRACE DEVICE =================
  static Future<Map<String, dynamic>?> getDeviceByCode(String code) async {
    try {
      code = code.trim().toUpperCase();

      final doc = await _db.collection('device_codes').doc(code).get();

      if (!doc.exists) {
        debugPrint("Code not found");
        return null;
      }

      return doc.data();
    } catch (e, stackTrace) {
      debugPrint("getDeviceByCode error: $e");
      debugPrint("Stack Trace: $stackTrace");
      return null;
    }
  }

  // ================= LOCATION UPDATE (OPTIONAL) =================
  static Future<void> updateDeviceLocation(
    String code,
    double lat,
    double lng,
  ) async {
    try {
      await _db.collection('device_codes').doc(code.toUpperCase()).update({
        'lastLocation': {
          'lat': lat,
          'lng': lng,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      });
    } catch (e, stackTrace) {
      debugPrint("updateDeviceLocation error: $e");
      debugPrint("Stack Trace: $stackTrace");
    }
  }
}
