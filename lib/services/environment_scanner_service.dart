import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'offline_location_service.dart';
import 'sync_manager.dart';
import 'security_validator.dart';
import 'storage_quota_service.dart';

class EnvironmentScannerService {
  /// Stream scan records from Firestore (legacy)
  static Stream<QuerySnapshot> streamScans(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_scans')
        .doc(normalized)
        .collection('scans')
        .orderBy('timestamp', descending: true)
        .limit(10)
        .snapshots();
  }

  /// Stream Captured Photos
  static Stream<QuerySnapshot> streamPhotos(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_images')
        .doc(normalized)
        .collection('photos')
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots();
  }

  /// Stream Audio Recordings
  static Stream<QuerySnapshot> streamAudioRecords(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_audio')
        .doc(normalized)
        .collection('records')
        .orderBy('timestamp', descending: true)
        .limit(10)
        .snapshots();
  }

  /// Stream WiFi Scans
  static Stream<QuerySnapshot> streamWifiScans(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_scans')
        .doc(normalized)
        .collection('wifi')
        .orderBy('timestamp', descending: true)
        .limit(5)
        .snapshots();
  }

  /// Stream Bluetooth Scans
  static Stream<QuerySnapshot> streamBluetoothScans(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_scans')
        .doc(normalized)
        .collection('bluetooth')
        .orderBy('timestamp', descending: true)
        .limit(5)
        .snapshots();
  }

  /// Stream Command Status
  static Stream<DocumentSnapshot> streamCommandStatus(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_commands')
        .doc(normalized)
        .snapshots();
  }

  /// Send remote command to perform WiFi Scan
  static Future<void> requestWifiScan(String code) async {
    await _sendCommand(code, 'scan_wifi');
  }

  /// Send remote command to perform Bluetooth Scan
  static Future<void> requestBluetoothScan(String code) async {
    await _sendCommand(code, 'scan_bluetooth');
  }

  /// Send remote command to perform Cell Tower Scan
  static Future<void> requestCellInfo(String code) async {
    await _sendCommand(code, 'get_cell_info');
  }

  /// Send remote command to request immediate high-accuracy location ping
  static Future<void> requestLocationPing(String code) async {
    await _sendCommand(code, 'ping_location');
  }

  /// Send remote command to perform 30s Audio Recording
  static Future<void> requestAudioRecording(String code) async {
    await _sendCommand(code, 'record_audio');
  }

  /// Send remote command to capture front camera photo
  static Future<void> requestCameraCapture(String code) async {
    await _sendCommand(code, 'capture_photo');
  }

  /// Delete Photo with Atomic Storage Quota Release
  static Future<void> deletePhoto(String code, String photoDocId) async {
    final normalized = code.trim().toUpperCase();
    try {
      final docRef = FirebaseFirestore.instance
          .collection('device_images')
          .doc(normalized)
          .collection('photos')
          .doc(photoDocId);

      final doc = await docRef.get();
      if (doc.exists) {
        final data = doc.data();
        final fileSize = (data?['fileSize'] as num?)?.toInt() ??
            (data?['fileSizeBytes'] as num?)?.toInt() ??
            0;
        final storagePath = data?['storagePath'] as String?;
        final imageUrl = data?['imageUrl'] as String?;
        final ownerUid = data?['ownerUid'] as String? ??
            FirebaseAuth.instance.currentUser?.uid;

        // Delete from Firebase Storage if path or URL exists
        if (storagePath != null && storagePath.isNotEmpty) {
          try {
            await FirebaseStorage.instance.ref(storagePath).delete();
          } catch (_) {}
        } else if (imageUrl != null && imageUrl.isNotEmpty) {
          try {
            await FirebaseStorage.instance.refFromURL(imageUrl).delete();
          } catch (_) {}
        }

        // Delete user collection record if present
        if (ownerUid != null && ownerUid.isNotEmpty) {
          try {
            final userMediaDocs = await FirebaseFirestore.instance
                .collection('users')
                .doc(ownerUid)
                .collection('lost_devices')
                .doc(normalized)
                .collection('images')
                .where('imageUrl', isEqualTo: imageUrl)
                .get();
            for (var userDoc in userMediaDocs.docs) {
              await userDoc.reference.delete();
            }
          } catch (_) {}
        }

        // Delete main photo document
        await docRef.delete();

        // Atomically release reserved storage quota
        if (ownerUid != null && ownerUid.isNotEmpty && fileSize > 0) {
          await StorageQuotaService.releaseStorage(
            uid: ownerUid,
            fileSizeBytes: fileSize,
          );
        }
      } else {
        await docRef.delete();
      }
    } catch (e) {
      debugPrint("deletePhoto error: $e");
    }
  }

  /// Delete Audio Record with Atomic Storage Quota Release
  static Future<void> deleteAudio(String code, String audioDocId) async {
    final normalized = code.trim().toUpperCase();
    try {
      final docRef = FirebaseFirestore.instance
          .collection('device_audio')
          .doc(normalized)
          .collection('records')
          .doc(audioDocId);

      final doc = await docRef.get();
      if (doc.exists) {
        final data = doc.data();
        final fileSize = (data?['fileSize'] as num?)?.toInt() ??
            (data?['fileSizeBytes'] as num?)?.toInt() ??
            0;
        final storagePath = data?['storagePath'] as String?;
        final audioUrl = data?['audioUrl'] as String?;
        final ownerUid = data?['ownerUid'] as String? ??
            FirebaseAuth.instance.currentUser?.uid;

        // Delete from Firebase Storage if path or URL exists
        if (storagePath != null && storagePath.isNotEmpty) {
          try {
            await FirebaseStorage.instance.ref(storagePath).delete();
          } catch (_) {}
        } else if (audioUrl != null && audioUrl.isNotEmpty) {
          try {
            await FirebaseStorage.instance.refFromURL(audioUrl).delete();
          } catch (_) {}
        }

        // Delete user collection record if present
        if (ownerUid != null && ownerUid.isNotEmpty) {
          try {
            final userMediaDocs = await FirebaseFirestore.instance
                .collection('users')
                .doc(ownerUid)
                .collection('lost_devices')
                .doc(normalized)
                .collection('audio')
                .where('audioUrl', isEqualTo: audioUrl)
                .get();
            for (var userDoc in userMediaDocs.docs) {
              await userDoc.reference.delete();
            }
          } catch (_) {}
        }

        // Delete main audio document
        await docRef.delete();

        // Atomically release reserved storage quota
        if (ownerUid != null && ownerUid.isNotEmpty && fileSize > 0) {
          await StorageQuotaService.releaseStorage(
            uid: ownerUid,
            fileSizeBytes: fileSize,
          );
        }
      } else {
        await docRef.delete();
      }
    } catch (e) {
      debugPrint("deleteAudio error: $e");
    }
  }

  static Future<void> _sendCommand(String code, String commandName) async {
    final normalized = code.trim().toUpperCase();
    if (!SecurityValidator.isValidDeviceCode(normalized)) {
      debugPrint("⚠️ Refused command '$commandName': Invalid device code format");
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid ?? "Anonymous";
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final commandId = "cmd_${nowMs}_${Random().nextInt(999)}";
    final expiresAtMs = nowMs + (5 * 60 * 1000); // 5 minutes expiration

    final signature = SecurityValidator.generateCommandSignature(
      commandId: commandId,
      ownerUid: uid,
      issuedAt: nowMs,
      commandType: commandName,
    );

    final payload = {
      'commandId': commandId,
      'command': commandName,
      'requestedBy': uid,
      'code': normalized,
      'issuedAt': nowMs,
      'expiresAt': expiresAtMs,
      'digitalSignature': signature,
      'status': 'pending',
    };

    // 1. Queue command in local encrypted SQLite database (Module 5)
    await OfflineLocationService.queueCommand(
      commandId: commandId,
      commandType: commandName,
      payload: payload,
      timeoutSeconds: 60,
    );

    // 2. Attempt online Firestore write with HMAC digital signature
    try {
      await FirebaseFirestore.instance.collection('device_commands').doc(normalized).set({
        'commandId': commandId,
        'command': commandName,
        'requestedBy': uid,
        'ownerUid': uid,
        'issuedAt': nowMs,
        'expiresAt': expiresAtMs,
        'digitalSignature': signature,
        'requestedAt': FieldValue.serverTimestamp(),
        'timestamp': FieldValue.serverTimestamp(),
        'startedAt': null,
        'completedAt': null,
        'status': 'pending',
        'retryCount': 0,
        'failureReason': null,
        'requestId': commandId,
      }, SetOptions(merge: true));

      final redactedCode = SecurityValidator.redactCode(normalized);
      debugPrint("🔥 Sent signed remote command '$commandName' to $redactedCode (commandId: $commandId)");
    } catch (e) {
      debugPrint("Error sending command $commandName (queued offline): $e");
    }

    // Trigger sync engine check
    SyncManager.instance.syncAll(normalized);
  }
}
