import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class TheftRiskResult {
  final int score;
  final List<String> factors;
  final String status;
  final bool isHighRisk;

  TheftRiskResult({
    required this.score,
    required this.factors,
    required this.status,
    required this.isHighRisk,
  });
}

class TheftDetectionService {
  /// Rule-Based Theft Risk Calculator with Configurable Weights:
  /// • SIM Removed = 30
  /// • GPS Disabled = 20
  /// • Airplane Mode = 15
  /// • Fast Movement = 15
  /// • Network Lost = 10
  /// • Pocket Removal = 10
  /// • Charger Unplugged = 5
  /// • Screen Locked = 5
  static TheftRiskResult calculateRiskScore({
    required bool isSimRemoved,
    required bool isGpsDisabled,
    required bool isAirplaneMode,
    required double speedMs,
    required bool isNetworkLost,
    required bool isPocketRemoval,
    bool isChargerUnplugged = false,
    bool isScreenLocked = false,
  }) {
    int score = 0;
    final List<String> factors = [];

    if (isSimRemoved) {
      score += 30;
      factors.add("SIM Removed");
    }

    if (isGpsDisabled) {
      score += 20;
      factors.add("GPS Disabled");
    }

    if (isAirplaneMode) {
      score += 15;
      factors.add("Airplane Mode Enabled");
    }

    if (speedMs > 4.5) {
      // Speed > 16 km/h (running or moving vehicle)
      score += 15;
      final speedKmh = (speedMs * 3.6).toStringAsFixed(1);
      factors.add("Fast Movement ($speedKmh km/h)");
    }

    if (isNetworkLost) {
      score += 10;
      factors.add("Internet Disconnected");
    }

    if (isPocketRemoval) {
      score += 10;
      factors.add("Phone Removed from Pocket");
    }

    if (isChargerUnplugged) {
      score += 5;
      factors.add("Charger Unplugged");
    }

    if (isScreenLocked) {
      score += 5;
      factors.add("Screen Locked / Turned Off");
    }

    final finalScore = score.clamp(0, 100);
    final isHigh = finalScore >= 50;
    final status = isHigh ? "Possible Theft Detected" : "Normal";

    return TheftRiskResult(
      score: finalScore,
      factors: factors,
      status: status,
      isHighRisk: isHigh,
    );
  }

  /// Evaluates telemetry data map from Firestore document
  static TheftRiskResult evaluateDocData(Map<String, dynamic> data) {
    final int rawScore = (data['riskScore'] as num?)?.toInt() ?? 0;
    final List<dynamic> rawFactors = data['riskFactors'] as List<dynamic>? ?? [];
    final List<String> factors = rawFactors.map((e) => e.toString()).toList();
    final String status = data['theftStatus']?.toString() ?? "Normal";

    final bool isGpsDisabled = data['isLocationEnabled'] == false;
    final bool isNetworkLost = data['isOnline'] == false;
    final double speed = (data['speed'] as num?)?.toDouble() ?? 0.0;

    if (rawScore > 0 || factors.isNotEmpty) {
      return TheftRiskResult(
        score: rawScore,
        factors: factors,
        status: status,
        isHighRisk: rawScore >= 50,
      );
    }

    return calculateRiskScore(
      isSimRemoved: false,
      isGpsDisabled: isGpsDisabled,
      isAirplaneMode: false,
      speedMs: speed,
      isNetworkLost: isNetworkLost,
      isPocketRemoval: false,
    );
  }

  /// Automatically triggers Lost Mode when high risk is detected
  static Future<void> autoTriggerLostMode(String code, TheftRiskResult result) async {
    if (!result.isHighRisk) return;
    try {
      final docRef = FirebaseFirestore.instance.collection('device_codes').doc(code);
      await docRef.update({
        'isLost': true,
        'traceRequestedAt': FieldValue.serverTimestamp(),
        'riskScore': result.score,
        'riskFactors': result.factors,
        'theftStatus': result.status,
      });

      // Log to timeline
      await FirebaseFirestore.instance
          .collection('device_timeline')
          .doc(code)
          .collection('events')
          .add({
        'eventType': 'THEFT_WARNING',
        'title': 'Possible Theft Detected (${result.score}%)',
        'description': 'Auto-activated Lost Mode. Factors: ${result.factors.join(', ')}',
        'timestamp': FieldValue.serverTimestamp(),
        'riskScore': result.score,
      });
      debugPrint("🔥 Auto-triggered Lost Mode for code $code (Risk ${result.score}%)");
    } catch (e) {
      debugPrint("Error auto-triggering Lost Mode: $e");
    }
  }
}
