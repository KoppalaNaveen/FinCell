import 'package:flutter/material.dart';
import '../services/ble_community_service.dart';

class CommunityDetectionCard extends StatelessWidget {
  final String deviceCode;

  const CommunityDetectionCard({
    super.key,
    required this.deviceCode,
  });

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    if (deviceCode.trim().isEmpty) return const SizedBox.shrink();

    return StreamBuilder<List<CommunityDetectionModel>>(
      stream: BLECommunityService.streamCommunityDetections(deviceCode),
      builder: (context, snapshot) {
        if (snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }

        final detection = snapshot.data!.first;

        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xff0D9488).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xff0D9488), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xff0D9488),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.bluetooth_searching, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Community Detection Available',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Color(0xff0F766E),
                          ),
                        ),
                        Text(
                          'Detected ${_formatTimeAgo(detection.detectedAt)} by nearby FinCell device',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.teal.shade900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: Colors.teal),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildMetricTile('Distance', '~${detection.approxDistanceMeters}m'),
                  _buildMetricTile('RSSI', '${detection.rssi} dBm'),
                  _buildMetricTile('Accuracy', '±${detection.accuracy.toStringAsFixed(0)}m'),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Coordinates: ${detection.latitude.toStringAsFixed(5)}, ${detection.longitude.toStringAsFixed(5)}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xff1E293B),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.shade200),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: Color(0xff0D9488)),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'This location is based on a nearby FinCell device detection and is approximate.',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontStyle: FontStyle.italic,
                          color: Color(0xff0F766E),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMetricTile(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xff0F766E)),
        ),
      ],
    );
  }
}
