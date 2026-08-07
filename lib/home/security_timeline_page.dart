import 'package:flutter/material.dart';
import '../services/theft_timeline_service.dart';

class SecurityTimelinePage extends StatelessWidget {
  final String deviceCode;

  const SecurityTimelinePage({super.key, required this.deviceCode});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: Text("Security Timeline ($deviceCode)"),
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 2,
      ),
      body: StreamBuilder<List<TimelineEventModel>>(
        stream: TheftTimelineService.streamTimeline(deviceCode),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.blue));
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                "Error loading timeline: ${snapshot.error}",
                style: const TextStyle(color: Colors.redAccent),
              ),
            );
          }

          final events = snapshot.data ?? [];
          if (events.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.timeline, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    "No security events recorded yet.",
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: events.length,
            itemBuilder: (context, index) {
              final event = events[index];
              return _buildTimelineCard(event, index == events.length - 1);
            },
          );
        },
      ),
    );
  }

  Widget _buildTimelineCard(TimelineEventModel event, bool isLast) {
    final ts = event.timestamp;
    final timeStr = "${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}:${ts.second.toString().padLeft(2, '0')} • ${ts.day}/${ts.month}/${ts.year}";

    Color eventColor;
    IconData iconData;

    switch (event.eventType) {
      case 'THEFT_WARNING':
        eventColor = Colors.redAccent;
        iconData = Icons.warning_amber_rounded;
        break;
      case 'CAMERA_CAPTURE':
        eventColor = Colors.amber;
        iconData = Icons.camera_alt;
        break;
      case 'AUDIO_RECORDING':
        eventColor = Colors.lightBlueAccent;
        iconData = Icons.mic;
        break;
      case 'SCAN_EVENT':
        eventColor = Colors.purpleAccent;
        iconData = Icons.wifi;
        break;
      default:
        eventColor = Colors.greenAccent;
        iconData = Icons.security;
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline indicator line
          Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: eventColor.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: eventColor, width: 2),
                ),
                child: Icon(iconData, size: 16, color: eventColor),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: Colors.grey.withValues(alpha: 0.3),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          // Event content card
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          event.title,
                          style: TextStyle(
                            color: eventColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      Text(
                        timeStr,
                        style: const TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ],
                  ),
                  if (event.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      event.description,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (event.lat != null && event.lng != null)
                        _buildChip(
                          Icons.location_on,
                          "${event.lat!.toStringAsFixed(4)}, ${event.lng!.toStringAsFixed(4)}",
                          Colors.blue,
                        ),
                      if (event.battery != null)
                        _buildChip(
                          Icons.battery_std,
                          "${event.battery}%",
                          Colors.green,
                        ),
                      if (event.speed != null && event.speed! > 0)
                        _buildChip(
                          Icons.speed,
                          "${(event.speed! * 3.6).toStringAsFixed(1)} km/h",
                          Colors.orange,
                        ),
                      if (event.riskScore != null)
                        _buildChip(
                          Icons.shield,
                          "Risk: ${event.riskScore}%",
                          Colors.red,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
