import 'package:flutter_test/flutter_test.dart';
import 'package:fincell/services/storage_quota_service.dart';

void main() {
  group('15 GB Per-User Storage Quota Tests', () {
    test('1. Exact 15 GB Byte Constant Calculation', () {
      // 15 GB = 15 * 1024 * 1024 * 1024 bytes
      const expectedBytes = 15 * 1024 * 1024 * 1024;
      expect(expectedBytes, equals(16106127360));
      expect(StorageQuotaService.quota15GbBytes, equals(16106127360));
    });

    test('2. Initial Remaining Bytes for New User', () {
      const quota = StorageQuotaService.quota15GbBytes;
      const initialUsed = 0;
      final remaining = StorageQuotaService.calculateRemainingBytes(quota, initialUsed);
      expect(remaining, equals(16106127360));

      final percent = StorageQuotaService.calculateUsagePercentage(quota, initialUsed);
      expect(percent, equals(0.0));
    });

    test('3. Storage Allocation and Remaining Calculation', () {
      const quota = StorageQuotaService.quota15GbBytes;
      const imageBytes = 2500000; // ~2.5 MB image
      const audioBytes = 1200000; // ~1.2 MB audio

      final used = imageBytes + audioBytes;
      final remaining = StorageQuotaService.calculateRemainingBytes(quota, used);

      expect(used, equals(3700000));
      expect(remaining, equals(16106127360 - 3700000));
      expect(remaining, equals(16102427360));
    });

    test('4. Boundary Condition - Exact Quota Match', () {
      const quota = StorageQuotaService.quota15GbBytes;
      final used = quota; // Exactly 15 GB used
      final remaining = StorageQuotaService.calculateRemainingBytes(quota, used);
      expect(remaining, equals(0));

      final percent = StorageQuotaService.calculateUsagePercentage(quota, used);
      expect(percent, equals(1.0));
    });

    test('5. Boundary Condition - Over Quota Rejection', () {
      const quota = StorageQuotaService.quota15GbBytes;
      const currentUsed = 16106120000; // 7,360 bytes remaining
      const incomingFile = 10000; // 10,000 bytes needed

      final isAllowed = (currentUsed + incomingFile) <= quota;
      expect(isAllowed, isFalse);

      final remaining = StorageQuotaService.calculateRemainingBytes(quota, currentUsed + incomingFile);
      expect(remaining, equals(0)); // Clamped at 0
    });

    test('6. Atomic Release and Non-Negative Clamping', () {
      const currentUsed = 5000000;
      const deletedFile = 2000000;
      final newUsed = (currentUsed - deletedFile).clamp(0, double.infinity).toInt();
      expect(newUsed, equals(3000000));

      // Attempting to release more than current used bytes
      const excessDeletion = 10000000;
      final clampedUsed = (currentUsed - excessDeletion).clamp(0, double.infinity).toInt();
      expect(clampedUsed, equals(0));
      expect(clampedUsed >= 0, isTrue);
    });

    test('7. Byte Formatting Accuracy (B, KB, MB, GB)', () {
      expect(StorageQuotaService.formatBytes(0), equals('0 B'));
      expect(StorageQuotaService.formatBytes(512), equals('512 B'));
      expect(StorageQuotaService.formatBytes(1024), equals('1.00 KB'));
      expect(StorageQuotaService.formatBytes(1048576), equals('1.00 MB'));
      expect(StorageQuotaService.formatBytes(1073741824), equals('1.00 GB'));
      expect(StorageQuotaService.formatBytes(16106127360), equals('15.00 GB'));
      expect(StorageQuotaService.formatBytes(null), equals('0 B'));
    });

    test('8. Rollback Idempotency / Single-Rollback Invariant', () {
      var currentUsed = 1000000;
      const reservationSize = 500000;

      // 1. Pre-upload reservation
      currentUsed += reservationSize;
      expect(currentUsed, equals(1500000));

      // Guarded rollback helper
      var rollbackApplied = false;
      void executeGuardedRollback() {
        if (!rollbackApplied) {
          currentUsed = (currentUsed - reservationSize).clamp(0, double.infinity).toInt();
          rollbackApplied = true;
        }
      }

      // 2. Upload fails -> trigger rollback once
      executeGuardedRollback();
      expect(currentUsed, equals(1000000));

      // 3. Second duplicate rollback attempted -> guard prevents duplicate deduction
      executeGuardedRollback();
      expect(currentUsed, equals(1000000));
    });
  });
}
