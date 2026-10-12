import 'dart:convert';
import 'package:crypto/crypto.dart';

class SecurityValidator {
  static const String _commandSecretKey = "FinCell_HMAC_Secret_Key_v1_Prod";

  /// Validates device code format (e.g. A-Z 0-9, 6 to 8 chars)
  static bool isValidDeviceCode(String? code) {
    if (code == null) return false;
    final clean = code.trim().toUpperCase();
    final regex = RegExp(r'^[A-Z0-9]{6,8}$');
    return regex.hasMatch(clean);
  }

  /// Validates coordinates latitude [-90, 90] and longitude [-180, 180]
  static bool isValidCoordinates(double? lat, double? lng) {
    if (lat == null || lng == null) return false;
    if (lat < -90 || lat > 90) return false;
    if (lng < -180 || lng > 180) return false;
    if (lat == 0.0 && lng == 0.0) return false; // Ignore default zero origin
    return true;
  }

  /// Generates HMAC-SHA256 signature for remote command authorization
  static String generateCommandSignature({
    required String commandId,
    required String ownerUid,
    required int issuedAt,
    required String commandType,
  }) {
    final payload = "$commandId:$ownerUid:$issuedAt:$commandType";
    final key = utf8.encode(_commandSecretKey);
    final bytes = utf8.encode(payload);
    final hmac = Hmac(sha256, key);
    return hmac.convert(bytes).toString();
  }

  /// Verifies digital signature of incoming command
  static bool verifyCommandSignature({
    required String commandId,
    required String ownerUid,
    required int issuedAt,
    required String commandType,
    required String signature,
  }) {
    if (signature.isEmpty) return false;
    final expected = generateCommandSignature(
      commandId: commandId,
      ownerUid: ownerUid,
      issuedAt: issuedAt,
      commandType: commandType,
    );
    return expected == signature;
  }

  /// Redacts sensitive device code for logging
  static String redactCode(String? code) {
    if (code == null || code.isEmpty) return "[REDACTED]";
    if (code.length <= 2) return "${code[0]}*";
    return "${code.substring(0, 2)}***${code.substring(code.length - 1)}";
  }

  /// Redacts sensitive coordinates for logging
  static String redactCoordinates(double? lat, double? lng) {
    if (lat == null || lng == null) return "[REDACTED_COORDS]";
    return "${lat.toStringAsFixed(1)}*, ${lng.toStringAsFixed(1)}*";
  }

  /// Redacts sensitive User UIDs for logging
  static String redactUid(String? uid) {
    if (uid == null || uid.isEmpty) return "[REDACTED_UID]";
    if (uid.length <= 4) return "${uid[0]}***";
    return "${uid.substring(0, 3)}***${uid.substring(uid.length - 2)}";
  }
}
