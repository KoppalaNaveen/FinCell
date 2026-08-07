import 'dart:math';
import 'package:latlong2/latlong.dart';

enum PredictionState {
  collectingData,
  offline,
  stationary,
  predicted,
}

class PredictionResult {
  final PredictionState state;
  final String destination;
  final int confidencePercentage;
  final String description;

  PredictionResult({
    required this.state,
    required this.destination,
    required this.confidencePercentage,
    required this.description,
  });
}

class MovementPredictionService {
  /// Predicts likely destination based on speed, heading angle, and position trajectory history
  static PredictionResult predictMovement({
    required LatLng? currentPos,
    required double speedMs,
    required double headingDeg,
    required bool isOnline,
    required int historyCount,
  }) {
    // 1. If device is offline
    if (!isOnline) {
      return PredictionResult(
        state: PredictionState.offline,
        destination: "Prediction unavailable.",
        confidencePercentage: 0,
        description: "Lost device is offline.",
      );
    }

    // 2. If not enough location history points gathered yet
    if (historyCount < 2) {
      return PredictionResult(
        state: PredictionState.collectingData,
        destination: "Collecting movement data...",
        confidencePercentage: 0,
        description: "Please wait while enough location history is gathered.",
      );
    }

    // 3. If stationary / slow movement
    if (currentPos == null || speedMs < 0.8) {
      return PredictionResult(
        state: PredictionState.stationary,
        destination: "Stationary / Paused",
        confidencePercentage: 92,
        description: "Device has not moved recently.",
      );
    }

    final double speedKmh = speedMs * 3.6;
    final String directionText = _getHeadingText(headingDeg);

    // 4. Sufficient movement history -> Predict from specified categories:
    // [Railway Station, Bus Stand, Market, Highway, Airport, College, Home, Office]
    if (speedKmh > 60.0) {
      return PredictionResult(
        state: PredictionState.predicted,
        destination: "Highway",
        confidencePercentage: min(96, (80 + (speedKmh / 5)).toInt()),
        description: "High speed movement ($speedKmh km/h) heading $directionText towards Highway.",
      );
    } else if (speedKmh > 35.0) {
      if (headingDeg >= 45 && headingDeg <= 135) {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "Railway Station",
          confidencePercentage: 87,
          description: "Transit speed ($speedKmh km/h) heading East towards Railway Station.",
        );
      } else if (headingDeg >= 135 && headingDeg <= 225) {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "Bus Stand",
          confidencePercentage: 85,
          description: "Moving South at $speedKmh km/h towards Bus Stand.",
        );
      } else if (headingDeg >= 225 && headingDeg <= 315) {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "Airport",
          confidencePercentage: 83,
          description: "Moving West at $speedKmh km/h towards Airport Corridor.",
        );
      } else {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "Highway",
          confidencePercentage: 80,
          description: "Moving North towards Intercity Highway.",
        );
      }
    } else if (speedKmh > 15.0) {
      if (headingDeg >= 0 && headingDeg < 90) {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "Market",
          confidencePercentage: 79,
          description: "Local velocity ($speedKmh km/h) heading towards Market area.",
        );
      } else if (headingDeg >= 90 && headingDeg < 180) {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "College",
          confidencePercentage: 77,
          description: "Moving at $speedKmh km/h towards Institutional / College Campus.",
        );
      } else if (headingDeg >= 180 && headingDeg < 270) {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "Office",
          confidencePercentage: 75,
          description: "Moving at $speedKmh km/h towards Business / Office Sector.",
        );
      } else {
        return PredictionResult(
          state: PredictionState.predicted,
          destination: "Home",
          confidencePercentage: 74,
          description: "Heading North-West towards Residential / Home Sector.",
        );
      }
    } else {
      return PredictionResult(
        state: PredictionState.stationary,
        destination: "Stationary / Paused",
        confidencePercentage: 90,
        description: "Device has not moved recently.",
      );
    }
  }

  static String _getHeadingText(double headingDeg) {
    if (headingDeg >= 337.5 || headingDeg < 22.5) return "North";
    if (headingDeg >= 22.5 && headingDeg < 67.5) return "North-East";
    if (headingDeg >= 67.5 && headingDeg < 112.5) return "East";
    if (headingDeg >= 112.5 && headingDeg < 157.5) return "South-East";
    if (headingDeg >= 157.5 && headingDeg < 202.5) return "South";
    if (headingDeg >= 202.5 && headingDeg < 247.5) return "South-West";
    if (headingDeg >= 247.5 && headingDeg < 292.5) return "West";
    return "North-West";
  }
}
