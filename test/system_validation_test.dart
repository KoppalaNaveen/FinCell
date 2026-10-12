import 'package:flutter_test/flutter_test.dart';
import 'package:fincell/services/security_validator.dart';
import 'package:fincell/services/offline_location_service.dart';
import 'package:fincell/services/sync_manager.dart';
import 'package:fincell/services/offline_direct_trace_service.dart';

void main() {
  group('1. SecurityValidator & Cryptography Hardening Tests', () {
    test('Device Code Format Validation', () {
      expect(SecurityValidator.isValidDeviceCode('FIN1234'), isTrue);
      expect(SecurityValidator.isValidDeviceCode('AB123456'), isTrue);
      expect(SecurityValidator.isValidDeviceCode('invalid_code_too_long'), isFalse);
      expect(SecurityValidator.isValidDeviceCode('123'), isFalse);
      expect(SecurityValidator.isValidDeviceCode(''), isFalse);
      expect(SecurityValidator.isValidDeviceCode(null), isFalse);
    });

    test('Coordinates Bounds Check Validation', () {
      expect(SecurityValidator.isValidCoordinates(12.9716, 77.5946), isTrue);
      expect(SecurityValidator.isValidCoordinates(-90.0, 180.0), isTrue);
      expect(SecurityValidator.isValidCoordinates(90.1, 77.5946), isFalse);
      expect(SecurityValidator.isValidCoordinates(12.9716, -180.1), isFalse);
      expect(SecurityValidator.isValidCoordinates(0.0, 0.0), isFalse);
      expect(SecurityValidator.isValidCoordinates(null, 77.5946), isFalse);
    });

    test('HMAC-SHA256 Command Digital Signature Verification', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final signature = SecurityValidator.generateCommandSignature(
        commandId: 'cmd_123456',
        ownerUid: 'uid_test_99',
        issuedAt: nowMs,
        commandType: 'capture_photo',
      );

      expect(signature.isNotEmpty, isTrue);

      final isValid = SecurityValidator.verifyCommandSignature(
        commandId: 'cmd_123456',
        ownerUid: 'uid_test_99',
        issuedAt: nowMs,
        commandType: 'capture_photo',
        signature: signature,
      );

      expect(isValid, isTrue);

      // Verify tampered command payload is rejected
      final isTampered = SecurityValidator.verifyCommandSignature(
        commandId: 'cmd_123456',
        ownerUid: 'uid_test_99',
        issuedAt: nowMs,
        commandType: 'ring_alarm', // Modified command
        signature: signature,
      );

      expect(isTampered, isFalse);
    });

    test('Log Redaction & Privacy Sanitization', () {
      expect(SecurityValidator.redactCode('FINCELL1'), equals('FI***1'));
      expect(SecurityValidator.redactCoordinates(12.97159, 77.59456), equals('13.0*, 77.6*'));
      expect(SecurityValidator.redactUid('usr_uid_super_secret_123'), equals('usr***23'));
    });
  });

  group('2. Offline Data Structure & Telemetry Models', () {
    test('EncryptedLocationRecord Model Verification', () {
      final rec = EncryptedLocationRecord(
        id: 101,
        latitude: 12.9716,
        longitude: 77.5946,
        speed: 1.5,
        heading: 180.0,
        accuracy: 5.0,
        altitude: 900.0,
        battery: 88,
        timestamp: '2026-08-07T16:00:00.000Z',
        networkType: 'WIFI',
        gpsStatus: 'HIGH_ACCURACY',
        riskScore: 15,
        isSynced: false,
        createdAt: 1786185600000,
        retryCount: 0,
      );

      expect(rec.id, equals(101));
      expect(rec.latitude, equals(12.9716));
      expect(rec.isSynced, isFalse);
    });

    test('SyncProgress Broadcast Model Verification', () {
      final progress = SyncProgress(
        isOnline: true,
        isSyncing: true,
        pendingLocationsCount: 42,
        pendingTimelineCount: 5,
        totalSyncedCount: 100,
        statusMessage: 'Uploading batch of 100 location records...',
        lastSyncTime: DateTime(2026, 8, 7, 16, 0),
      );

      expect(progress.isOnline, isTrue);
      expect(progress.isSyncing, isTrue);
      expect(progress.pendingLocationsCount, equals(42));
      expect(progress.pendingTimelineCount, equals(5));
      expect(progress.totalSyncedCount, equals(100));
    });

    test('DirectTelemetry Model Parsing & Bounds Verification', () {
      final now = DateTime.now();
      final telemetry = DirectTelemetry(
        latitude: 12.9716,
        longitude: 77.5946,
        accuracy: 4.5,
        speed: 1.2,
        heading: 180.0,
        altitude: 920.0,
        battery: 92,
        gpsStatus: 'AVAILABLE',
        isLocationEnabled: true,
        timestamp: now,
        isOnline: false,
        deviceState: 'Direct Connection',
        transport: 'Direct Local Network',
      );

      expect(telemetry.latitude, equals(12.9716));
      expect(telemetry.longitude, equals(77.5946));
      expect(telemetry.accuracy, equals(4.5));
      expect(telemetry.battery, equals(92));
      expect(telemetry.isLocationEnabled, isTrue);
      expect(telemetry.deviceState, equals('Direct Connection'));
      expect(telemetry.transport, equals('Direct Local Network'));

      // From JSON constructor test
      final fromJson = DirectTelemetry.fromJson({
        'latitude': 13.0827,
        'longitude': 80.2707,
        'accuracy': 3.0,
        'speed': 0.0,
        'heading': 90.0,
        'altitude': 10.0,
        'battery': 85,
        'gpsStatus': 'AVAILABLE',
        'isLocationEnabled': true,
        'timestamp': now.millisecondsSinceEpoch,
        'isOnline': false,
        'deviceState': 'Direct Connection',
      }, transport: 'Direct BLE');

      expect(fromJson.latitude, equals(13.0827));
      expect(fromJson.longitude, equals(80.2707));
      expect(fromJson.battery, equals(85));
      expect(fromJson.transport, equals('Direct BLE'));
    });

    test('Direct Trace HMAC Handshake Token Verification', () {
      const deviceCode = 'YD2NJG';
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      // Probe signature
      final probeSig = SecurityValidator.generateCommandSignature(
        commandId: 'probe_$nowMs',
        ownerUid: deviceCode,
        issuedAt: nowMs,
        commandType: 'offline_telemetry_probe',
      );

      final isProbeValid = SecurityValidator.verifyCommandSignature(
        commandId: 'probe_$nowMs',
        ownerUid: deviceCode,
        issuedAt: nowMs,
        commandType: 'offline_telemetry_probe',
        signature: probeSig,
      );

      expect(isProbeValid, isTrue);

      // Response signature
      final respSig = SecurityValidator.generateCommandSignature(
        commandId: 'resp_$nowMs',
        ownerUid: deviceCode,
        issuedAt: nowMs,
        commandType: 'offline_telemetry_response',
      );

      final isRespValid = SecurityValidator.verifyCommandSignature(
        commandId: 'resp_$nowMs',
        ownerUid: deviceCode,
        issuedAt: nowMs,
        commandType: 'offline_telemetry_response',
        signature: respSig,
      );

      expect(isRespValid, isTrue);
    });
  });
}
