import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'battery_service.dart';

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
    int batteryLevel = -1,
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
      data['accuracy'] = initialPosition.accuracy;
      data['speed'] = initialPosition.speed;
      data['heading'] = initialPosition.heading;
      data['batteryLevel'] = batteryLevel;
      data['lastLocation'] = {
        'lat': initialPosition.latitude,
        'lng': initialPosition.longitude,
        'accuracy': initialPosition.accuracy,
        'speed': initialPosition.speed,
        'heading': initialPosition.heading,
        'battery': batteryLevel,
        'updatedAt': FieldValue.serverTimestamp(),
      };
    }

    return data;
  }

  static Future<Position?> _loadInitialPositionForCode() async {
    try {
      final lastKnown = await Geolocator.getLastKnownPosition().timeout(
        const Duration(seconds: 1),
        onTimeout: () => null,
      );
      if (lastKnown != null) {
        debugPrint("Initial Location Loaded from Cache: ${lastKnown.latitude}, ${lastKnown.longitude}");
        return lastKnown;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 2),
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException("Location timeout"),
      );
      debugPrint("Initial Location Loaded: ${position.latitude}, ${position.longitude}");
      return position;
    } catch (e) {
      debugPrint("Initial Location Skipped: $e");
      return null;
    }
  }

  static Future<bool> _cacheCode({
    required SharedPreferences prefs,
    required String uid,
    required String code,
  }) async {
    try {
      await prefs.setString('device_bound_code', code);
      await prefs.setString('device_code', code);
      final savedUnique = await prefs.setString('uniqueCode', code);
      final savedUid = await prefs.setString('cached_code_$uid', code);

      debugPrint(
        "SharedPreferences Saved: uniqueCode=$savedUnique cached_code_$uid=$savedUid device_bound_code=$code",
      );

      return savedUnique && savedUid;
    } catch (e, stackTrace) {
      debugPrint("SharedPreferences Save Failed: $e");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  // ================= DEVICE-BOUND PERSISTENT CODE =================
  static Future<String?> getDeviceBoundCode(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('device_bound_code') ??
          prefs.getString('device_code') ??
          prefs.getString('uniqueCode');
      if (cached != null && cached.trim().isNotEmpty) {
        return cached.trim().toUpperCase();
      }

      if (deviceId.isNotEmpty) {
        final querySnap = await _db
            .collection('device_codes')
            .where('deviceId', isEqualTo: deviceId)
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 3));

        if (querySnap.docs.isNotEmpty) {
          final foundCode = querySnap.docs.first.id.trim().toUpperCase();
          await prefs.setString('device_bound_code', foundCode);
          await prefs.setString('uniqueCode', foundCode);
          return foundCode;
        }
      }
    } catch (e) {
      debugPrint("Notice getting device-bound code: $e");
    }
    return null;
  }

  static Future<String?> ensureDeviceBoundCodeForUser(String uid, String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Check user's own doc first
      final userRef = _db.collection('users').doc(uid);
      try {
        final userDoc = await userRef.get().timeout(const Duration(seconds: 3));
        final existing = _readExistingCode(userDoc.data());
        if (existing != null) {
          await _cacheCode(prefs: prefs, uid: uid, code: existing);
          return existing;
        }
      } catch (_) {}

      // If user has no code yet, check if this physical device already created a code
      final boundCode = await getDeviceBoundCode(deviceId);
      if (boundCode != null && boundCode.isNotEmpty) {
        debugPrint("Binding existing device code $boundCode to user $uid");
        final codeRef = _db.collection('device_codes').doc(boundCode);

        try {
          await userRef.set(_userCodeData(boundCode), SetOptions(merge: true)).timeout(const Duration(seconds: 3));
          await codeRef.set({
            'ownerUid': uid,
            'deviceId': deviceId,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)).timeout(const Duration(seconds: 3));
        } catch (_) {}

        await _cacheCode(prefs: prefs, uid: uid, code: boundCode);
        return boundCode;
      }
    } catch (e) {
      debugPrint("Notice ensuring device-bound code: $e");
    }
    return null;
  }

  // ================= ERROR MAPPING HELPER =================
  static String _mapErrorMessage(Object error) {
    if (error is SocketException || error is TimeoutException) {
      return "Unable to create device code. Please check your internet connection.";
    }
    if (error is FirebaseException) {
      if (error.code == 'permission-denied') {
        return "Permission denied while creating device code.";
      }
      if (error.code == 'unavailable' || error.code == 'network-request-failed') {
        return "Unable to create device code. Please check your internet connection.";
      }
      if (error.code == 'unauthenticated') {
        return "Authentication required. Please log in again.";
      }
    }
    final str = error.toString();
    if (str.contains("Device code already exists") ||
        str.contains("already exists") ||
        str.contains("already taken")) {
      return "Device code already exists. Please choose another code.";
    }
    if (str.contains("Please enter a valid device code") ||
        str.contains("valid device code") ||
        str.contains("characters long")) {
      return "Please enter a valid device code.";
    }
    if (str.contains("Please enter a device code")) {
      return "Please enter a device code.";
    }
    if (str.contains("Authentication required") ||
        str.contains("not logged in") ||
        str.contains("unauthenticated")) {
      return "Authentication required. Please log in again.";
    }
    if (str.contains("Permission denied") || str.contains("permission-denied")) {
      return "Permission denied while creating device code.";
    }
    if (str.contains("internet") ||
        str.contains("network") ||
        str.contains("unavailable") ||
        str.contains("SocketException")) {
      return "Unable to create device code. Please check your internet connection.";
    }
    return "Unable to create device code. Please try again.";
  }

  // ================= SYSTEM GENERATED CODE =================
  static Future<CodeResult> generateSystemCode(String deviceId) async {
    debugPrint("Create Device Code: started");

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint("Create Device Code Failed: user is null");
      return CodeResult(
        success: false,
        message: "Authentication required. Please log in again.",
      );
    }

    final uid = user.uid;
    final effectiveDeviceId =
        deviceId.isNotEmpty ? deviceId : "device_${DateTime.now().millisecondsSinceEpoch}";
    debugPrint("Current UID: $uid, Device ID: $effectiveDeviceId");

    try {
      final prefs = await SharedPreferences.getInstance();
      final userRef = _db.collection('users').doc(uid);
      Position? initialPosition;
      try {
        initialPosition = await _loadInitialPositionForCode();
      } catch (e) {
        debugPrint("Notice loading initial position: $e");
      }

      int battery = -1;
      try {
        battery = await BatteryService.getBatteryLevel().timeout(
          const Duration(seconds: 2),
          onTimeout: () => -1,
        );
      } catch (_) {}

      // 1. Check if device already has a persistent code
      final boundCode = await getDeviceBoundCode(effectiveDeviceId);
      if (boundCode != null && boundCode.isNotEmpty) {
        final existingCodeRef = _db.collection('device_codes').doc(boundCode);
        final devData = _deviceCodeData(
          uid: uid,
          deviceId: effectiveDeviceId,
          code: boundCode,
          includeCreatedAt: false,
          initialPosition: initialPosition,
          batteryLevel: battery,
        );
        try {
          await existingCodeRef.set(devData, SetOptions(merge: true));
          await userRef.set(_userCodeData(boundCode), SetOptions(merge: true));
        } catch (_) {}

        await _cacheCode(prefs: prefs, uid: uid, code: boundCode);
        return CodeResult(
          success: true,
          code: boundCode,
          message: "Code retrieved successfully",
        );
      }

      // 2. Check if user already has an existing code
      try {
        final userDoc = await userRef.get().timeout(const Duration(seconds: 4));
        final existingCode = _readExistingCode(userDoc.data());
        if (existingCode != null) {
          debugPrint("Existing Device Code Found: $existingCode");
          final existingCodeRef = _db.collection('device_codes').doc(existingCode);
          final existingCodeDoc = await existingCodeRef.get().timeout(const Duration(seconds: 4));
          final ownerUid = existingCodeDoc.data()?['ownerUid']?.toString();

          if (!existingCodeDoc.exists || ownerUid == null || ownerUid == uid) {
            final devData = _deviceCodeData(
              uid: uid,
              deviceId: effectiveDeviceId,
              code: existingCode,
              includeCreatedAt: !existingCodeDoc.exists,
              initialPosition: initialPosition,
              batteryLevel: battery,
            );
            await existingCodeRef.set(devData, SetOptions(merge: true));
            await userRef.set(_userCodeData(existingCode), SetOptions(merge: true));
            await _cacheCode(prefs: prefs, uid: uid, code: existingCode);

            return CodeResult(
              success: true,
              code: existingCode,
              message: "Code retrieved successfully",
            );
          }
        }
      } catch (e) {
        debugPrint("Check existing code check warning: $e");
      }

      // Generate a new unique code
      String? chosenCode;
      for (int i = 0; i < 10; i++) {
        final candidate = _randomCode();
        try {
          final codeRef = _db.collection('device_codes').doc(candidate);
          final doc = await codeRef.get().timeout(const Duration(seconds: 2));
          if (!doc.exists) {
            chosenCode = candidate;
            break;
          }
        } catch (_) {
          chosenCode = candidate;
          break;
        }
      }

      chosenCode ??= _randomCode();

      final codeRef = _db.collection('device_codes').doc(chosenCode);
      final devData = _deviceCodeData(
        uid: uid,
        deviceId: effectiveDeviceId,
        code: chosenCode,
        includeCreatedAt: true,
        initialPosition: initialPosition,
        batteryLevel: battery,
      );

      // Direct write to live Firestore
      try {
        debugPrint("Writing auto-generated code $chosenCode to Firestore...");
        await codeRef.set(devData, SetOptions(merge: true));
        await userRef.set(_userCodeData(chosenCode), SetOptions(merge: true));
      } catch (e, st) {
        debugPrint("Firestore code generation write FAILED: ${e.runtimeType}: $e\n$st");
        return CodeResult(
          success: false,
          message: _mapErrorMessage(e),
        );
      }

      await _cacheCode(prefs: prefs, uid: uid, code: chosenCode);

      debugPrint("Device code generated and saved successfully in Firestore: $chosenCode");
      return CodeResult(
        success: true,
        code: chosenCode,
        message: "Code created successfully",
      );
    } catch (e, stackTrace) {
      debugPrint("generateSystemCode OUTER CATCH: ${e.runtimeType}: $e");
      debugPrint("Stack Trace: $stackTrace");

      return CodeResult(
        success: false,
        message: _mapErrorMessage(e),
      );
    }
  }

  // ================= CUSTOM / MANUAL CODE =================
  static Future<CodeResult> createCustomCode(
    String inputCode,
    String deviceId,
  ) async {
    debugPrint("Custom Device Code Creation: started");

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint("Custom Device Code Failed: user is null");
      return CodeResult(
        success: false,
        message: "Authentication required. Please log in again.",
      );
    }

    final trimmed = inputCode.trim();
    if (trimmed.isEmpty) {
      return CodeResult(
        success: false,
        message: "Please enter a device code.",
      );
    }

    final code = trimmed.toUpperCase();
    if (!isValidFormat(code)) {
      return CodeResult(
        success: false,
        message: "Code must be 6 to 8 alphanumeric characters.",
      );
    }

    final uid = user.uid;
    final effectiveDeviceId =
        deviceId.isNotEmpty ? deviceId : "device_${DateTime.now().millisecondsSinceEpoch}";
    debugPrint("Current UID: $uid, Requested Custom Code: $code");

    try {
      final prefs = await SharedPreferences.getInstance();
      final ref = _db.collection('device_codes').doc(code);
      final userRef = _db.collection('users').doc(uid);

      Position? initialPosition;
      try {
        initialPosition = await _loadInitialPositionForCode();
      } catch (e) {
        debugPrint("Notice loading initial position: $e");
      }

      // 1. Check if the requested code already belongs to someone else
      try {
        final existingDoc = await ref.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 6));
        if (existingDoc.exists) {
          final existingOwner = existingDoc.data()?['ownerUid']?.toString();
          if (existingOwner != null && existingOwner.isNotEmpty && existingOwner != uid) {
            return CodeResult(
              success: false,
              message: "Device code already exists. Please choose another code.",
            );
          }
        }
      } catch (e) {
        debugPrint("Notice checking code uniqueness (will try to create anyway): $e");
        // If we can't check, try from cache
        try {
          final cachedDoc = await ref.get(const GetOptions(source: Source.cache));
          if (cachedDoc.exists) {
            final existingOwner = cachedDoc.data()?['ownerUid']?.toString();
            if (existingOwner != null && existingOwner.isNotEmpty && existingOwner != uid) {
              return CodeResult(
                success: false,
                message: "Device code already exists. Please choose another code.",
              );
            }
          }
        } catch (_) {}
      }

      // 2. Check old code to delete if user had one before
      String? oldCode;
      try {
        final userDoc = await userRef.get().timeout(const Duration(seconds: 3));
        oldCode = _readExistingCode(userDoc.data());
      } catch (_) {}

      int battery = -1;
      try {
        battery = await BatteryService.getBatteryLevel().timeout(
          const Duration(seconds: 2),
          onTimeout: () => -1,
        );
      } catch (_) {}

      final devData = _deviceCodeData(
        uid: uid,
        deviceId: effectiveDeviceId,
        code: code,
        includeCreatedAt: true,
        initialPosition: initialPosition,
        batteryLevel: battery,
      );

      // 3. Write to Firestore — force server write, not just local cache
      try {
        debugPrint("Writing device code $code to Firestore...");

        // Write device code document
        await ref.set(devData, SetOptions(merge: true));

        // Write user document
        await userRef.set(_userCodeData(code), SetOptions(merge: true));

        // Force a server read to verify the write actually went through
        try {
          await ref.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 6));
          debugPrint("Server verification: device code $code confirmed on server");
        } catch (verifyError) {
          debugPrint("Server verification skipped (offline?): $verifyError");
          // Don't fail — the write was committed locally and will sync later
        }

        if (oldCode != null && oldCode != code) {
          try {
            await _db.collection('device_codes').doc(oldCode).delete().timeout(const Duration(seconds: 3));
          } catch (_) {}
        }
      } catch (e, st) {
        debugPrint("Firestore custom code write FAILED: $e");
        debugPrint("Error type: ${e.runtimeType}");
        debugPrint("Stack Trace: $st");
        return CodeResult(
          success: false,
          message: _mapErrorMessage(e),
        );
      }

      await _cacheCode(prefs: prefs, uid: uid, code: code);

      debugPrint("Custom device code saved successfully: $code");
      return CodeResult(
        success: true,
        code: code,
        message: "Code created successfully",
      );
    } catch (e, stackTrace) {
      debugPrint("createCustomCode OUTER CATCH: ${e.runtimeType}: $e");
      debugPrint("Stack Trace: $stackTrace");

      return CodeResult(
        success: false,
        message: _mapErrorMessage(e),
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
      await _db.collection('device_codes').doc(code.toUpperCase()).set({
        'latitude': lat,
        'longitude': lng,
        'updatedAt': FieldValue.serverTimestamp(),
        'lastLocation': {
          'lat': lat,
          'lng': lng,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      }, SetOptions(merge: true));
    } catch (e, stackTrace) {
      debugPrint("updateDeviceLocation error: $e");
      debugPrint("Stack Trace: $stackTrace");
    }
  }
}

