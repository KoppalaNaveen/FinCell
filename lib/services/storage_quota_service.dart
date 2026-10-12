import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service responsible for managing the 15 GB storage quota allocated to
/// each FinCell user specifically for automatically captured lost-device media.
class StorageQuotaService {
  /// Total storage quota per FinCell user: exactly 15 GB in bytes (15 * 1024^3).
  static const int quota15GbBytes = 16106127360;

  /// Safely initializes or backfills the 15 GB quota fields in the user's
  /// Firestore document without overwriting or resetting existing user data.
  static Future<void> ensureUserStorageQuota(String uid) async {
    if (uid.isEmpty) return;
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null && currentUser.uid == uid && currentUser.isAnonymous) {
        // Guest users MUST NOT receive the 15 GB storage quota
        return;
      }

      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final doc = await userRef.get();

      if (!doc.exists) {
        await userRef.set({
          'storageQuotaBytes': quota15GbBytes,
          'storageUsedBytes': 0,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        final data = doc.data();
        if (data?['isGuest'] == true) {
          // Skip guest users
          return;
        }
        final updates = <String, dynamic>{};
        if (data == null || !data.containsKey('storageQuotaBytes')) {
          updates['storageQuotaBytes'] = quota15GbBytes;
        }
        if (data == null || !data.containsKey('storageUsedBytes')) {
          updates['storageUsedBytes'] = 0;
        }
        if (updates.isNotEmpty) {
          updates['updatedAt'] = FieldValue.serverTimestamp();
          await userRef.set(updates, SetOptions(merge: true));
        }
      }
    } catch (e) {
      debugPrint("StorageQuotaService.ensureUserStorageQuota notice: $e");
    }
  }

  /// Atomically reserves [fileSizeBytes] in the user's storage quota using
  /// a Firestore transaction BEFORE initiating a media upload.
  ///
  /// Returns `true` if the reservation was granted, or `false` if insufficient quota remains.
  static Future<bool> reserveStorage({
    required String uid,
    required int fileSizeBytes,
  }) async {
    if (uid.isEmpty || fileSizeBytes <= 0) return false;

    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

    try {
      return await FirebaseFirestore.instance.runTransaction<bool>(
        (transaction) async {
          final snapshot = await transaction.get(userRef);

          final quota = snapshot.data()?['storageQuotaBytes'] as int? ?? quota15GbBytes;
          final currentUsed = snapshot.data()?['storageUsedBytes'] as int? ?? 0;

          if (currentUsed + fileSizeBytes > quota) {
            debugPrint(
              "⚠️ Storage reservation rejected for user $uid: "
              "currentUsed=$currentUsed + incoming=$fileSizeBytes exceeds quota=$quota",
            );
            return false;
          }

          final newUsed = currentUsed + fileSizeBytes;
          transaction.set(
            userRef,
            {
              'storageQuotaBytes': quota,
              'storageUsedBytes': newUsed,
              'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );

          return true;
        },
      );
    } catch (e) {
      debugPrint("StorageQuotaService.reserveStorage transaction error: $e");
      return false;
    }
  }

  /// Atomically releases [fileSizeBytes] from the user's storage quota using
  /// a Firestore transaction (e.g. upon upload rollback or media deletion).
  ///
  /// Guarantees that `storageUsedBytes` never drops below 0.
  static Future<void> releaseStorage({
    required String uid,
    required int fileSizeBytes,
  }) async {
    if (uid.isEmpty || fileSizeBytes <= 0) return;

    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final snapshot = await transaction.get(userRef);
        if (!snapshot.exists) return;

        final currentUsed = snapshot.data()?['storageUsedBytes'] as int? ?? 0;
        final newUsed = max(0, currentUsed - fileSizeBytes);

        transaction.set(
          userRef,
          {
            'storageUsedBytes': newUsed,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      });
    } catch (e) {
      debugPrint("StorageQuotaService.releaseStorage transaction error: $e");
    }
  }

  /// Formats byte numbers into exact human-readable strings (B, KB, MB, GB).
  static String formatBytes(num? bytes) {
    if (bytes == null || bytes <= 0) return "0 B";

    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = 0;
    double count = bytes.toDouble();

    while (count >= 1024 && i < suffixes.length - 1) {
      count /= 1024;
      i++;
    }

    if (i == 0) {
      return "${count.toInt()} ${suffixes[i]}";
    } else {
      return "${count.toStringAsFixed(2)} ${suffixes[i]}";
    }
  }

  /// Calculates remaining bytes given quota and used bytes.
  static int calculateRemainingBytes(int quotaBytes, int usedBytes) {
    return max(0, quotaBytes - usedBytes);
  }

  /// Calculates usage percentage clamped between 0.0 and 1.0.
  static double calculateUsagePercentage(int quotaBytes, int usedBytes) {
    if (quotaBytes <= 0) return 0.0;
    return (usedBytes / quotaBytes).clamp(0.0, 1.0);
  }
}
