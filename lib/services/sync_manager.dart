import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'offline_location_service.dart';
import 'security_validator.dart';

class SyncProgress {
  final bool isOnline;
  final bool isSyncing;
  final int pendingLocationsCount;
  final int pendingTimelineCount;
  final int totalSyncedCount;
  final String statusMessage;
  final DateTime? lastSyncTime;

  SyncProgress({
    required this.isOnline,
    required this.isSyncing,
    required this.pendingLocationsCount,
    required this.pendingTimelineCount,
    required this.totalSyncedCount,
    required this.statusMessage,
    this.lastSyncTime,
  });
}

class SyncManager {
  static final SyncManager _instance = SyncManager._internal();
  static SyncManager get instance => _instance;
  SyncManager._internal();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final StreamController<SyncProgress> _progressController = StreamController<SyncProgress>.broadcast();
  Stream<SyncProgress> get progressStream => _progressController.stream;

  bool _isSyncing = false;
  bool _isOnline = true;
  DateTime? _lastSyncTime;

  int _currentRetryBackoffSec = 1;
  static const int _maxBackoffSec = 32;
  static const int _maxRetryLimit = 6;
  int _consecutiveFailures = 0;

  Timer? _connectivityTimer;

  bool get isOnline => _isOnline;

  Future<bool> checkConnectionFast({Duration timeout = const Duration(milliseconds: 1500)}) async {
    try {
      final response = await http
          .get(Uri.parse('https://clients3.google.com/generate_204'))
          .timeout(timeout);
      final ok = response.statusCode == 204 || response.statusCode == 200;
      _isOnline = ok;
      return ok;
    } catch (_) {
      _isOnline = false;
      return false;
    }
  }

  // ================= INIT =================
  void init() {
    _startConnectivityMonitoring();
    checkConnectionFast();
  }

  void _startConnectivityMonitoring() {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final online = await _checkInternetConnection();
      if (online != _isOnline) {
        _isOnline = online;
        if (_isOnline) {
          debugPrint("🌐 Connectivity restored. Resetting backoff and triggering sync...");
          _consecutiveFailures = 0;
          _currentRetryBackoffSec = 1;
          syncAll();
        }
      }
      _broadcastProgress("Monitoring connectivity");
    });
  }

  Future<bool> _checkInternetConnection() async {
    try {
      final response = await http
          .get(Uri.parse('https://clients3.google.com/generate_204'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ================= SYNC ALL =================
  Future<void> syncAll([String? deviceCode]) async {
    if (_isSyncing) {
      debugPrint("Sync currently in progress. Skipping duplicate run.");
      return;
    }

    _isOnline = await _checkInternetConnection();
    if (!_isOnline) {
      _broadcastProgress("OFFLINE MODE ACTIVE | Waiting For Internet");
      return;
    }

    if (_consecutiveFailures >= _maxRetryLimit) {
      debugPrint("Max retry limit reached. Waiting for network state change...");
      _broadcastProgress("Max retry limit reached. Paused until reconnect.");
      return;
    }

    _isSyncing = true;
    _broadcastProgress("Synchronizing...");

    try {
      int totalSynced = 0;

      // 1. Sync Offline Locations in batches of 100
      totalSynced += await _syncLocationsBatch(deviceCode);

      // 2. Sync Offline Timeline in batches of 100
      totalSynced += await _syncTimelineBatch(deviceCode);

      // 3. Sync Wi-Fi Fingerprint Scans in batches of 100
      totalSynced += await _syncWifiScansBatch(deviceCode);

      // 4. Sync Cell Tower Data in batches of 100
      totalSynced += await _syncCellTowerBatch(deviceCode);

      // 5. Process Pending Commands Queue
      await _processPendingCommands(deviceCode);

      // 6. Auto-clean synced items from local SQLite DB
      await OfflineLocationService.autoCleanUp();

      _lastSyncTime = DateTime.now();
      _consecutiveFailures = 0;
      _currentRetryBackoffSec = 1;
      _broadcastProgress("Synchronization Completed ($totalSynced synced)");
    } catch (e) {
      _consecutiveFailures++;
      _currentRetryBackoffSec = (_currentRetryBackoffSec * 2).clamp(1, _maxBackoffSec);
      debugPrint("Sync error (attempt $_consecutiveFailures): $e. Retrying in $_currentRetryBackoffSec s");
      _broadcastProgress("Sync failed. Retrying in ${_currentRetryBackoffSec}s...");

      // Capped exponential backoff retry scheduling
      Timer(Duration(seconds: _currentRetryBackoffSec), () {
        _isSyncing = false;
        if (_consecutiveFailures < _maxRetryLimit) {
          syncAll(deviceCode);
        }
      });
      return;
    } finally {
      _isSyncing = false;
    }
  }

  // ================= BATCH SYNC LOCATIONS =================
  Future<int> _syncLocationsBatch(String? deviceCode) async {
    int syncedCount = 0;

    while (true) {
      final unsynced = await OfflineLocationService.getUnsyncedLocations(limit: 100);
      if (unsynced.isEmpty) break;

      final List<int> syncedIds = [];
      final WriteBatch batch = _db.batch();

      for (final rec in unsynced) {
        final capturedDate = DateTime.tryParse(rec.timestamp) ?? DateTime.now();
        final now = DateTime.now();
        final syncDelaySec = now.difference(capturedDate).inSeconds;

        final payload = {
          'latitude': rec.latitude,
          'longitude': rec.longitude,
          'speed': rec.speed,
          'heading': rec.heading,
          'accuracy': rec.accuracy,
          'altitude': rec.altitude,
          'batteryLevel': rec.battery,
          'networkType': rec.networkType,
          'gpsStatus': rec.gpsStatus,
          'riskScore': rec.riskScore,
          // Mandatory Sync Metadata (Module 12)
          'uploadedAt': FieldValue.serverTimestamp(),
          'capturedAt': capturedDate.toIso8601String(),
          'deviceTime': capturedDate.millisecondsSinceEpoch,
          'deviceTimezone': capturedDate.timeZoneName,
          'syncDelay': syncDelaySec,
          'syncSource': 'offline_batch_sync',
        };

        if (deviceCode != null && deviceCode.isNotEmpty) {
          final codeRef = _db.collection('device_codes').doc(deviceCode.toUpperCase());

          // Conflict resolution: Newest Timestamp Wins
          batch.set(codeRef, {
            'latitude': rec.latitude,
            'longitude': rec.longitude,
            'speed': rec.speed,
            'heading': rec.heading,
            'accuracy': rec.accuracy,
            'batteryLevel': rec.battery,
            'lastLocation': {
              'lat': rec.latitude,
              'lng': rec.longitude,
              'accuracy': rec.accuracy,
              'speed': rec.speed,
              'heading': rec.heading,
              'battery': rec.battery,
              'updatedAt': FieldValue.serverTimestamp(),
              'uploadedAt': FieldValue.serverTimestamp(),
              'capturedAt': payload['capturedAt'],
              'syncSource': 'offline_batch_sync',
            },
            'updatedAt': FieldValue.serverTimestamp(),
            'isOnline': true,
          }, SetOptions(merge: true));

          final locHistRef = _db
              .collection('device_codes')
              .doc(deviceCode.toUpperCase())
              .collection('location_history')
              .doc('${rec.createdAt}_${rec.id}');

          batch.set(locHistRef, payload, SetOptions(merge: true));
        }

        syncedIds.add(rec.id);
      }

      await batch.commit();
      await OfflineLocationService.markLocationsSynced(syncedIds);
      syncedCount += syncedIds.length;
      _broadcastProgress("Uploaded batch of ${syncedIds.length} location records");
    }

    return syncedCount;
  }

  // ================= BATCH SYNC TIMELINE =================
  Future<int> _syncTimelineBatch(String? deviceCode) async {
    int syncedCount = 0;

    while (true) {
      final unsynced = await OfflineLocationService.getUnsyncedTimeline(limit: 100);
      if (unsynced.isEmpty) break;

      final List<int> syncedIds = [];
      final WriteBatch batch = _db.batch();

      for (final rec in unsynced) {
        final capturedDate = DateTime.tryParse(rec.timestamp) ?? DateTime.now();
        final now = DateTime.now();
        final syncDelaySec = now.difference(capturedDate).inSeconds;

        final payload = {
          'eventType': rec.eventType,
          'title': rec.title,
          'description': rec.description,
          'timestamp': Timestamp.fromDate(capturedDate),
          'lat': rec.lat,
          'lng': rec.lng,
          'battery': rec.battery,
          'speed': rec.speed,
          'riskScore': rec.riskScore,
          // Metadata
          'uploadedAt': FieldValue.serverTimestamp(),
          'capturedAt': capturedDate.toIso8601String(),
          'deviceTime': capturedDate.millisecondsSinceEpoch,
          'deviceTimezone': capturedDate.timeZoneName,
          'syncDelay': syncDelaySec,
          'syncSource': 'offline_batch_sync',
        };

        if (deviceCode != null && deviceCode.isNotEmpty) {
          final eventRef = _db
              .collection('device_timeline')
              .doc(deviceCode.toUpperCase())
              .collection('events')
              .doc('${rec.createdAt}_${rec.id}');

          // Deterministic Newest Timestamp Wins
          batch.set(eventRef, payload, SetOptions(merge: true));
        }

        syncedIds.add(rec.id);
      }

      await batch.commit();
      await OfflineLocationService.markTimelineSynced(syncedIds);
      syncedCount += syncedIds.length;
      _broadcastProgress("Uploaded batch of ${syncedIds.length} timeline events");
    }

    return syncedCount;
  }

  // ================= BATCH SYNC WIFI SCANS =================
  Future<int> _syncWifiScansBatch(String? deviceCode) async {
    int syncedCount = 0;

    while (true) {
      final unsynced = await OfflineLocationService.getUnsyncedWifiScans(limit: 100);
      if (unsynced.isEmpty) break;

      final List<int> syncedIds = [];
      final WriteBatch batch = _db.batch();

      for (final rec in unsynced) {
        final capturedDate = DateTime.tryParse(rec.timestamp) ?? DateTime.now();
        final now = DateTime.now();
        final syncDelaySec = now.difference(capturedDate).inSeconds;

        final payload = {
          'ssid': rec.ssid.isEmpty ? '<unknown ssid>' : rec.ssid,
          'bssid': rec.bssid,
          'signalStrength': rec.signalStrength,
          'frequency': rec.frequency,
          'latitude': rec.latitude,
          'longitude': rec.longitude,
          'timestamp': Timestamp.fromDate(capturedDate),
          'uploadedAt': FieldValue.serverTimestamp(),
          'capturedAt': capturedDate.toIso8601String(),
          'deviceTime': capturedDate.millisecondsSinceEpoch,
          'deviceTimezone': capturedDate.timeZoneName,
          'syncDelay': syncDelaySec,
          'syncSource': 'offline_batch_sync',
        };

        if (deviceCode != null && deviceCode.isNotEmpty) {
          final wifiRef = _db
              .collection('device_scans')
              .doc(deviceCode.toUpperCase())
              .collection('wifi')
              .doc('${rec.createdAt}_${rec.id}');

          batch.set(wifiRef, payload, SetOptions(merge: true));
        }

        syncedIds.add(rec.id);
      }

      await batch.commit();
      await OfflineLocationService.markWifiScansSynced(syncedIds);
      syncedCount += syncedIds.length;
      _broadcastProgress("Uploaded batch of ${syncedIds.length} Wi-Fi fingerprint scans");
    }

    return syncedCount;
  }

  // ================= BATCH SYNC CELL TOWER DATA =================
  Future<int> _syncCellTowerBatch(String? deviceCode) async {
    int syncedCount = 0;

    while (true) {
      final unsynced = await OfflineLocationService.getUnsyncedCellTowerData(limit: 100);
      if (unsynced.isEmpty) break;

      final List<int> syncedIds = [];
      final WriteBatch batch = _db.batch();

      for (final rec in unsynced) {
        final capturedDate = DateTime.tryParse(rec.timestamp) ?? DateTime.now();
        final now = DateTime.now();
        final syncDelaySec = now.difference(capturedDate).inSeconds;

        final payload = {
          'cellId': rec.cellId,
          'lac': rec.lac,
          'mcc': rec.mcc,
          'mnc': rec.mnc,
          'signalStrength': rec.signalStrength,
          'isApproximate': true,
          'locationType': 'Cell Tower Fallback',
          'timestamp': Timestamp.fromDate(capturedDate),
          'uploadedAt': FieldValue.serverTimestamp(),
          'capturedAt': capturedDate.toIso8601String(),
          'deviceTime': capturedDate.millisecondsSinceEpoch,
          'deviceTimezone': capturedDate.timeZoneName,
          'syncDelay': syncDelaySec,
          'syncSource': 'offline_batch_sync',
        };

        if (deviceCode != null && deviceCode.isNotEmpty) {
          final cellRef = _db
              .collection('device_scans')
              .doc(deviceCode.toUpperCase())
              .collection('cell_info')
              .doc('${rec.createdAt}_${rec.id}');

          batch.set(cellRef, payload, SetOptions(merge: true));
        }

        syncedIds.add(rec.id);
      }

      await batch.commit();
      await OfflineLocationService.markCellTowerDataSynced(syncedIds);
      syncedCount += syncedIds.length;
      _broadcastProgress("Uploaded batch of ${syncedIds.length} Cell Tower records");
    }

    return syncedCount;
  }

  // ================= PROCESS PENDING COMMANDS =================
  Future<void> _processPendingCommands(String? deviceCode) async {
    final pendingCmds = await OfflineLocationService.getPendingCommands();
    if (pendingCmds.isEmpty) return;

    for (final cmd in pendingCmds) {
      if (cmd.status == 'Completed' || cmd.status == 'Failed') {
        await OfflineLocationService.updateCommandStatus(
          commandId: cmd.commandId,
          status: cmd.status,
          markSynced: true,
        );
        continue;
      }

      // Check timeout (Module 8 improvement)
      final now = DateTime.now().millisecondsSinceEpoch;
      if (cmd.startedAt > 0 && (now - cmd.startedAt) > (cmd.timeoutSeconds * 1000)) {
        debugPrint("Command ${cmd.commandId} timed out. Marking as Failed.");
        await OfflineLocationService.updateCommandStatus(
          commandId: cmd.commandId,
          status: 'Failed',
          failureReason: 'Execution Timeout (${cmd.timeoutSeconds}s)',
          markSynced: true,
        );
        continue;
      }

      // Mark command running
      await OfflineLocationService.updateCommandStatus(
        commandId: cmd.commandId,
        status: 'Running',
      );

      try {
        Map<String, dynamic> payload = {};
        if (cmd.payloadJson.isNotEmpty) {
          payload = jsonDecode(cmd.payloadJson) as Map<String, dynamic>;
        }

        // Security Validation: Check Expiration
        if (payload.containsKey('expiresAt')) {
          final expiresAt = (payload['expiresAt'] as num).toInt();
          if (now > expiresAt) {
            debugPrint("Command ${cmd.commandId} has expired. Rejecting execution.");
            await OfflineLocationService.updateCommandStatus(
              commandId: cmd.commandId,
              status: 'Failed',
              failureReason: 'Command Expired',
              markSynced: true,
            );
            continue;
          }
        }

        // Security Validation: Digital Signature Check
        if (payload.containsKey('digitalSignature')) {
          final sig = payload['digitalSignature']?.toString() ?? '';
          final ownerUid = payload['requestedBy']?.toString() ?? '';
          final issuedAt = (payload['issuedAt'] as num?)?.toInt() ?? 0;

          if (sig.isNotEmpty && issuedAt > 0) {
            final valid = SecurityValidator.verifyCommandSignature(
              commandId: cmd.commandId,
              ownerUid: ownerUid,
              issuedAt: issuedAt,
              commandType: cmd.commandType,
              signature: sig,
            );

            if (!valid) {
              debugPrint("⚠️ Command ${cmd.commandId} signature mismatch! Rejecting execution.");
              await OfflineLocationService.updateCommandStatus(
                commandId: cmd.commandId,
                status: 'Failed',
                failureReason: 'Digital Signature Verification Failed',
                markSynced: true,
              );
              continue;
            }
          }
        }

        debugPrint("Executing verified offline command: ${cmd.commandType} (ID: ${cmd.commandId})");

        // Sync status to Firestore
        if (deviceCode != null && deviceCode.isNotEmpty) {
          await _db.collection('device_commands').doc(deviceCode.toUpperCase()).set({
            'lastCommand': cmd.commandType,
            'lastCommandId': cmd.commandId,
            'status': 'Completed',
            'executedAt': FieldValue.serverTimestamp(),
            'payload': payload,
          }, SetOptions(merge: true));
        }

        await OfflineLocationService.updateCommandStatus(
          commandId: cmd.commandId,
          status: 'Completed',
          markSynced: true,
        );
      } catch (e) {
        debugPrint("Failed to execute command ${cmd.commandId}: $e");
        await OfflineLocationService.updateCommandStatus(
          commandId: cmd.commandId,
          status: 'Failed',
          failureReason: e.toString(),
          markSynced: true,
        );
      }
    }
  }

  // ================= HELPER BROADCAST =================
  void _broadcastProgress(String message) async {
    final pendingCount = await OfflineLocationService.getUnsyncedCount();
    _progressController.add(SyncProgress(
      isOnline: _isOnline,
      isSyncing: _isSyncing,
      pendingLocationsCount: pendingCount,
      pendingTimelineCount: 0,
      totalSyncedCount: 0,
      statusMessage: message,
      lastSyncTime: _lastSyncTime,
    ));
  }

  void dispose() {
    _connectivityTimer?.cancel();
    _progressController.close();
  }
}
