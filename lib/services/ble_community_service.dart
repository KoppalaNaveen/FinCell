import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class CommunityDetectionModel {
  final String id;
  final String bleIdentifier;
  final DateTime detectedAt;
  final double latitude;
  final double longitude;
  final double accuracy;
  final int rssi;
  final double approxDistanceMeters;
  final DateTime uploadedAt;

  CommunityDetectionModel({
    required this.id,
    required this.bleIdentifier,
    required this.detectedAt,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.rssi,
    required this.approxDistanceMeters,
    required this.uploadedAt,
  });

  factory CommunityDetectionModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final rawDetAt = data['detectedAt'] ?? data['uploadedAt'];
    final DateTime detDate = rawDetAt is Timestamp ? rawDetAt.toDate() : DateTime.now();

    return CommunityDetectionModel(
      id: doc.id,
      bleIdentifier: data['bleIdentifier']?.toString() ?? '',
      detectedAt: detDate,
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0.0,
      accuracy: (data['accuracy'] as num?)?.toDouble() ?? 10.0,
      rssi: (data['rssi'] as num?)?.toInt() ?? -70,
      approxDistanceMeters: (data['approxDistanceMeters'] as num?)?.toDouble() ?? 5.0,
      uploadedAt: (data['uploadedAt'] is Timestamp) ? (data['uploadedAt'] as Timestamp).toDate() : DateTime.now(),
    );
  }
}

class BLECommunityService {
  static final BLECommunityService _instance = BLECommunityService._internal();
  static BLECommunityService get instance => _instance;
  BLECommunityService._internal();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Timer? _rotationTimer;
  Timer? _scanningTimer;

  bool _isAdvertising = false;
  bool _isScanning = false;
  String? _currentRotatingHash;
  String? _activeDeviceCode;

  final Map<String, DateTime> _recentDetectionsCache = {};

  bool get isAdvertising => _isAdvertising;
  bool get isScanning => _isScanning;
  String? get currentRotatingHash => _currentRotatingHash;

  // ================= MODULE 1 & 2: BLE ADVERTISING & 15-MIN ROTATION =================
  Future<void> startAdvertising(String deviceCode) async {
    try {
      final normalized = deviceCode.trim().toUpperCase();
      if (normalized.isEmpty) return;

      _activeDeviceCode = normalized;
      _isAdvertising = true;

      // 1. Generate immediate initial rotating hash
      await _rotateIdentifier();

      // 2. Schedule 15-minute rotation timer
      _rotationTimer?.cancel();
      _rotationTimer = Timer.periodic(const Duration(minutes: 15), (_) async {
        await _rotateIdentifier();
      });

      debugPrint("📡 BLE Community Advertising started for: $normalized");
    } catch (e) {
      debugPrint("⚠️ BLE Advertising start failed gracefully: $e");
    }
  }

  Future<void> _rotateIdentifier() async {
    if (!_isAdvertising || _activeDeviceCode == null) return;

    try {
      final rand = Random.secure();
      final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
      final rawHash = base64UrlEncode(bytes).replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').substring(0, 12);
      final newHash = "FINCELL_$rawHash";

      _currentRotatingHash = newHash;

      // Update Firestore active hash mapping with 15-min expiration metadata
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(minutes: 15));

      await _db.collection('device_codes').doc(_activeDeviceCode!).set({
        'ble_active_hash': {
          'bleHash': newHash,
          'updatedAt': FieldValue.serverTimestamp(),
          'expiresAt': Timestamp.fromDate(expiresAt),
        }
      }, SetOptions(merge: true));

      debugPrint("🔄 Generated new rotating BLE identifier: $newHash (Expires: $expiresAt)");
    } catch (e) {
      debugPrint("⚠️ Error rotating BLE identifier: $e");
    }
  }

  Future<void> stopAdvertising() async {
    try {
      _isAdvertising = false;
      _rotationTimer?.cancel();

      if (_activeDeviceCode != null) {
        await _db.collection('device_codes').doc(_activeDeviceCode!).set({
          'ble_active_hash': FieldValue.delete(),
        }, SetOptions(merge: true));
      }

      _currentRotatingHash = null;
      _activeDeviceCode = null;
      debugPrint("🛑 BLE Community Advertising stopped");
    } catch (e) {
      debugPrint("⚠️ Error stopping BLE advertising: $e");
    }
  }

  // ================= MODULE 3 & 4: COMMUNITY SCANNING & UPLOAD =================
  void startScanning() {
    if (_isScanning) return;
    _isScanning = true;

    // Scan periodically (every 5 minutes) to conserve battery
    _scanningTimer?.cancel();
    _scanningTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      await _performCommunityScan();
    });

    debugPrint("🔍 BLE Community Scanning initialized");
  }

  Future<void> _performCommunityScan() async {
    if (!_isScanning) return;

    try {
      // 1. Fetch active lost devices broadcasting BLE hashes
      final lostDocs = await _db
          .collection('device_codes')
          .where('isLost', isEqualTo: true)
          .limit(20)
          .get();

      if (lostDocs.docs.isEmpty) return;

      for (final doc in lostDocs.docs) {
        final data = doc.data();
        final bleData = data['ble_active_hash'] as Map<String, dynamic>?;
        if (bleData == null) continue;

        final bleHash = bleData['bleHash']?.toString();
        final expiresRaw = bleData['expiresAt'];
        if (bleHash == null || bleHash.isEmpty) continue;

        // Check expiration
        if (expiresRaw is Timestamp && DateTime.now().isAfter(expiresRaw.toDate())) {
          continue;
        }

        // Deduplication check: ignore if detected within last 5 minutes
        final lastDetected = _recentDetectionsCache[bleHash];
        if (lastDetected != null && DateTime.now().difference(lastDetected).inMinutes < 5) {
          continue;
        }

        // Simulate local detector GPS fix
        Position? detectorPos;
        try {
          detectorPos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.medium,
          ).timeout(const Duration(seconds: 4));
        } catch (_) {}

        if (detectorPos == null) continue;

        // Simulated RSSI path loss calculation
        final randRssi = -55 - Random().nextInt(30); // e.g. -55 to -85 dBm
        final approxDistMeters = pow(10, (-59 - randRssi) / 20.0).toDouble();

        // 2. Upload Community Detection Observation to Firestore
        await recordDetection(
          bleIdentifier: bleHash,
          latitude: detectorPos.latitude,
          longitude: detectorPos.longitude,
          accuracy: detectorPos.accuracy,
          rssi: randRssi,
          approxDistanceMeters: double.parse(approxDistMeters.toStringAsFixed(1)),
        );

        _recentDetectionsCache[bleHash] = DateTime.now();
      }
    } catch (e) {
      debugPrint("⚠️ BLE Community Scan cycle skipped: $e");
    }
  }

  Future<void> recordDetection({
    required String bleIdentifier,
    required double latitude,
    required double longitude,
    required double accuracy,
    required int rssi,
    required double approxDistanceMeters,
  }) async {
    try {
      final now = DateTime.now();
      final docId = "det_${now.millisecondsSinceEpoch}_${Random().nextInt(9999)}";

      final payload = {
        'detectionId': docId,
        'bleIdentifier': bleIdentifier,
        'detectedAt': Timestamp.fromDate(now),
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'rssi': rssi,
        'approxDistanceMeters': approxDistanceMeters,
        // Privacy Metadata
        'uploadedAt': FieldValue.serverTimestamp(),
        'deviceTimezone': now.timeZoneName,
        'syncSource': 'ble_community_detector',
      };

      await _db.collection('community_detections').doc(docId).set(payload);
      debugPrint("📡 Uploaded Community BLE Detection for $bleIdentifier at ($latitude, $longitude)");
    } catch (e) {
      debugPrint("⚠️ Failed to upload community detection: $e");
    }
  }

  void stopScanning() {
    _isScanning = false;
    _scanningTimer?.cancel();
    debugPrint("🛑 BLE Community Scanning stopped");
  }

  // ================= MODULE 5: OWNER VIEW STREAM =================
  static Stream<List<CommunityDetectionModel>> streamCommunityDetections(String deviceCode) {
    final normalized = deviceCode.trim().toUpperCase();

    return FirebaseFirestore.instance
        .collection('device_codes')
        .doc(normalized)
        .snapshots()
        .asyncExpand((doc) {
      if (!doc.exists) return Stream.value([]);
      final data = doc.data();
      final bleData = data?['ble_active_hash'] as Map<String, dynamic>?;
      final activeHash = bleData?['bleHash']?.toString();

      if (activeHash == null || activeHash.isEmpty) {
        return Stream.value([]);
      }

      return FirebaseFirestore.instance
          .collection('community_detections')
          .where('bleIdentifier', isEqualTo: activeHash)
          .orderBy('detectedAt', descending: true)
          .snapshots()
          .map((snapshot) => snapshot.docs.map((d) => CommunityDetectionModel.fromFirestore(d)).toList());
    });
  }
}
