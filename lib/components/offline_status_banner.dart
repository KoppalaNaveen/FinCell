import 'dart:async';
import 'package:flutter/material.dart';
import '../services/sync_manager.dart';

class OfflineStatusBanner extends StatefulWidget {
  const OfflineStatusBanner({super.key});

  @override
  State<OfflineStatusBanner> createState() => _OfflineStatusBannerState();
}

class _OfflineStatusBannerState extends State<OfflineStatusBanner> {
  StreamSubscription<SyncProgress>? _sub;
  SyncProgress? _lastProgress;
  Timer? _durationTimer;
  DateTime? _offlineStartTime;

  @override
  void initState() {
    super.initState();
    _sub = SyncManager.instance.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _lastProgress = progress;
          if (!progress.isOnline && _offlineStartTime == null) {
            _offlineStartTime = DateTime.now();
          } else if (progress.isOnline) {
            _offlineStartTime = null;
          }
        });
      }
    });

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _offlineStartTime != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _durationTimer?.cancel();
    super.dispose();
  }

  String _formatDuration(DateTime start) {
    final diff = DateTime.now().difference(start);
    final mins = diff.inMinutes;
    final secs = diff.inSeconds % 60;
    if (mins > 0) {
      return '${mins}m ${secs}s';
    }
    return '${secs}s';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _lastProgress;
    if (progress == null) return const SizedBox.shrink();

    // 1. OFFLINE MODE
    if (!progress.isOnline) {
      final durationStr = _offlineStartTime != null ? _formatDuration(_offlineStartTime!) : '0s';
      final lastSyncStr = progress.lastSyncTime != null ? _formatTime(progress.lastSyncTime!) : 'Never';

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.amber.shade900.withValues(alpha: 0.92),
          border: Border(bottom: BorderSide(color: Colors.amber.shade400, width: 1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'OFFLINE MODE ACTIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${progress.pendingLocationsCount} Cached',
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Tracking Locally • Waiting For Internet • Offline for $durationStr (Last Sync: $lastSyncStr)',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      );
    }

    // 2. SYNCHRONIZING
    if (progress.isSyncing) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.teal.shade800.withValues(alpha: 0.92),
          border: Border(bottom: BorderSide(color: Colors.teal.shade300, width: 1)),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Synchronizing... ${progress.statusMessage}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 3. RECENTLY COMPLETED
    if (progress.statusMessage.contains('Completed')) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: Colors.green.shade800.withValues(alpha: 0.9),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Text(
              progress.statusMessage,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
