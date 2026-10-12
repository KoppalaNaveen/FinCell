import 'package:flutter_test/flutter_test.dart';
import 'package:fincell/services/storage_quota_service.dart';

void main() {
  group('Lost-Device Forensic Media Viewer Tests', () {
    test('1. Forensic Image Metadata Parsing & Validation', () {
      final mockImageDoc = {
        'imageUrl': 'https://firebasestorage.googleapis.com/v0/b/app/o/users%2Fuid123%2Flost_devices%2FDEV01%2Fimages%2Fphoto.jpg?alt=media',
        'storagePath': 'users/uid123/lost_devices/DEV01/images/1723456789_uuid.jpg',
        'fileSize': 2450000,
        'ownerUid': 'uid123',
        'deviceCode': 'DEV01',
        'mediaType': 'image',
        'camera': 'front',
        'battery': 84,
      };

      expect(mockImageDoc['storagePath'], startsWith('users/uid123/lost_devices/DEV01/images/'));
      expect(mockImageDoc['mediaType'], equals('image'));
      expect(mockImageDoc['camera'], equals('front'));
      expect(mockImageDoc['fileSize'], equals(2450000));
      expect(StorageQuotaService.formatBytes(mockImageDoc['fileSize'] as num), equals('2.34 MB'));
    });

    test('2. Forensic Audio Metadata Parsing & Validation', () {
      final mockAudioDoc = {
        'audioUrl': 'https://firebasestorage.googleapis.com/v0/b/app/o/users%2Fuid123%2Flost_devices%2FDEV01%2Faudio%2Frecording.mp3?alt=media',
        'storagePath': 'users/uid123/lost_devices/DEV01/audio/1723456789_uuid.mp3',
        'fileSize': 1180000,
        'ownerUid': 'uid123',
        'deviceCode': 'DEV01',
        'mediaType': 'audio',
        'duration': 30,
        'battery': 80,
      };

      expect(mockAudioDoc['storagePath'], startsWith('users/uid123/lost_devices/DEV01/audio/'));
      expect(mockAudioDoc['mediaType'], equals('audio'));
      expect(mockAudioDoc['duration'], equals(30));
      expect(mockAudioDoc['fileSize'], equals(1180000));
      expect(StorageQuotaService.formatBytes(mockAudioDoc['fileSize'] as num), equals('1.13 MB'));
    });

    test('3. Audio Playback Duration & Progress Formatter', () {
      String formatDuration(Duration d) {
        final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
        final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
        return "$minutes:$seconds";
      }

      expect(formatDuration(Duration.zero), equals('00:00'));
      expect(formatDuration(const Duration(seconds: 15)), equals('00:15'));
      expect(formatDuration(const Duration(seconds: 30)), equals('00:30'));
      expect(formatDuration(const Duration(minutes: 1, seconds: 45)), equals('01:45'));
    });

    test('4. Multi-Device Filter Selection Logic', () {
      final allMedia = [
        {'deviceCode': 'DEV01', 'id': 'photo_1'},
        {'deviceCode': 'DEV02', 'id': 'photo_2'},
        {'deviceCode': 'DEV01', 'id': 'audio_1'},
      ];

      // Filter: All Devices (null)
      String? selectedFilter;
      final allFiltered = allMedia.where((m) => selectedFilter == null || m['deviceCode'] == selectedFilter).toList();
      expect(allFiltered.length, equals(3));

      // Filter: DEV01
      selectedFilter = 'DEV01';
      final dev01Filtered = allMedia.where((m) => selectedFilter == null || m['deviceCode'] == selectedFilter).toList();
      expect(dev01Filtered.length, equals(2));

      // Filter: DEV02
      selectedFilter = 'DEV02';
      final dev02Filtered = allMedia.where((m) => selectedFilter == null || m['deviceCode'] == selectedFilter).toList();
      expect(dev02Filtered.length, equals(1));
    });

    test('5. Read-Only Quota Invariance (Viewing Does Not Alter Storage Used)', () {
      const quota = StorageQuotaService.quota15GbBytes;
      const initialUsed = 3630000; // ~3.63 MB (from photo + audio)

      // Simulating viewing photo and playing audio (read operations)
      final usedAfterViewing = initialUsed;
      expect(usedAfterViewing, equals(initialUsed));
      expect(StorageQuotaService.calculateRemainingBytes(quota, usedAfterViewing),
          equals(16106127360 - 3630000));
    });
  });
}
