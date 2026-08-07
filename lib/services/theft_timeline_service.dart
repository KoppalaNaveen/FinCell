import 'package:cloud_firestore/cloud_firestore.dart';

class TimelineEventModel {
  final String id;
  final String eventType;
  final String title;
  final String description;
  final DateTime timestamp;
  final double? lat;
  final double? lng;
  final int? battery;
  final double? speed;
  final String? imageUrl;
  final String? audioUrl;
  final int? riskScore;

  TimelineEventModel({
    required this.id,
    required this.eventType,
    required this.title,
    required this.description,
    required this.timestamp,
    this.lat,
    this.lng,
    this.battery,
    this.speed,
    this.imageUrl,
    this.audioUrl,
    this.riskScore,
  });

  factory TimelineEventModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final rawTs = data['timestamp'];
    final DateTime ts = rawTs is Timestamp ? rawTs.toDate() : DateTime.now();

    return TimelineEventModel(
      id: doc.id,
      eventType: data['eventType']?.toString() ?? 'SYSTEM_EVENT',
      title: data['title']?.toString() ?? data['reason']?.toString() ?? 'Security Event',
      description: data['description']?.toString() ?? '',
      timestamp: ts,
      lat: (data['lat'] as num?)?.toDouble(),
      lng: (data['lng'] as num?)?.toDouble(),
      battery: (data['battery'] as num?)?.toInt(),
      speed: (data['speed'] as num?)?.toDouble(),
      imageUrl: data['imageUrl']?.toString(),
      audioUrl: data['audioUrl']?.toString(),
      riskScore: (data['riskScore'] as num?)?.toInt(),
    );
  }
}

class TheftTimelineService {
  /// Stream of security timeline events for a given device code
  static Stream<List<TimelineEventModel>> streamTimeline(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_timeline')
        .doc(normalized)
        .collection('events')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) => TimelineEventModel.fromFirestore(doc)).toList());
  }

  /// Manually log a timeline event from Flutter
  static Future<void> logEvent({
    required String code,
    required String eventType,
    required String title,
    required String description,
    double? lat,
    double? lng,
    int? battery,
    double? speed,
    int? riskScore,
  }) async {
    final normalized = code.trim().toUpperCase();
    try {
      await FirebaseFirestore.instance
          .collection('device_timeline')
          .doc(normalized)
          .collection('events')
          .add({
        'eventType': eventType,
        'title': title,
        'description': description,
        'timestamp': FieldValue.serverTimestamp(),
        'lat': lat,
        'lng': lng,
        'battery': battery,
        'speed': speed,
        'riskScore': riskScore,
      });
    } catch (_) {}
  }
}
