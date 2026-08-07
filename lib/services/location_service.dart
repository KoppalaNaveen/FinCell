import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'offline_location_service.dart';

class LocationService {

  static StreamSubscription<Position>? _positionStream;
  static StreamSubscription<DocumentSnapshot>? _commandSubscription;
  static StreamSubscription<DocumentSnapshot>? _codeSubscription;

  // ================= START CONTINUOUS TRACKING =================

  void startTracking(String codeOrDeviceId) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
          return;
        }
      }

      // Initial immediate high accuracy fix
      updateLocation(codeOrDeviceId);

      _listenToRemoteCommands(codeOrDeviceId);

      if (_positionStream != null) return;

      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        ),
      ).listen((Position pos) {
        _sendLocation(pos, codeOrDeviceId);
      });

    } catch (e) {
      // silent fail
    }
  }

  void _listenToRemoteCommands(String codeOrDeviceId) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    _codeSubscription?.cancel();
    _commandSubscription?.cancel();

    // Listen to code document for trace requests or code updates
    FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get()
        .then((doc) {
      final code = doc.data()?['uniqueCode'] ?? codeOrDeviceId;
      if (code == null || code.isEmpty) return;

      final normalizedCode = code.toString().trim().toUpperCase();

      _codeSubscription = FirebaseFirestore.instance
          .collection('device_codes')
          .doc(normalizedCode)
          .snapshots()
          .listen((snap) {
        if (!snap.exists) return;
        final data = snap.data();
        if (data == null) return;

        final bool isLost = data['isLost'] == true;
        final traceRequestedAt = data['traceRequestedAt'];

        if (isLost || traceRequestedAt != null) {
          updateLocation(normalizedCode);
        }
      });

      _commandSubscription = FirebaseFirestore.instance
          .collection('device_commands')
          .doc(normalizedCode)
          .snapshots()
          .listen((snap) async {
        if (!snap.exists) return;
        final data = snap.data();
        if (data == null) return;

        final String status = data['status']?.toString() ?? '';
        final String command = data['command']?.toString() ?? '';

        if (status == 'pending' && command.isNotEmpty) {
          if (command == 'ping_location' || command == 'request_update') {
            await updateLocation(normalizedCode);
            await FirebaseFirestore.instance
                .collection('device_commands')
                .doc(normalizedCode)
                .set({
              'status': 'completed',
              'completedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
        }
      });
    }).catchError((_) {});
  }

  // ================= STOP TRACKING =================

  void stopTracking() {
    _positionStream?.cancel();
    _positionStream = null;
    _commandSubscription?.cancel();
    _commandSubscription = null;
    _codeSubscription?.cancel();
    _codeSubscription = null;
  }

  // ================= SEND LOCATION =================

  Future<void> _sendLocation(Position pos, [String? targetCode]) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final db = FirebaseFirestore.instance;

      String? uniqueCode = targetCode;

      if (uniqueCode == null || uniqueCode.isEmpty) {
        if (uid != null) {
          final userDoc = await db.collection('users').doc(uid).get();
          if (userDoc.exists) {
            uniqueCode = userDoc.data()?['uniqueCode'];
          }
        }
      }

      if (uniqueCode == null || uniqueCode.isEmpty) return;

      final normalizedCode = uniqueCode.trim().toUpperCase();

      try {
        await db.collection('device_codes').doc(normalizedCode).set({
          'latitude': pos.latitude,
          'longitude': pos.longitude,
          'timestamp': FieldValue.serverTimestamp(),
          'isOnline': true,
          'isLocationEnabled': true,
          'speed': pos.speed,
          'heading': pos.heading,
          'batteryLevel': 100,
          'lastSeen': FieldValue.serverTimestamp(),
          'lastLocation': {
            'lat': pos.latitude,
            'lng': pos.longitude,
            'accuracy': pos.accuracy,
            'speed': pos.speed,
            'heading': pos.heading,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        await syncOfflineLocations(normalizedCode);
      } catch (e) {
        await OfflineLocationService.saveLocation(
          pos.latitude,
          pos.longitude,
        );
      }
    } catch (e) {
      // silent fail
    }
  }

  // ================= SINGLE UPDATE =================

  Future<void> updateLocation([String? codeOrDeviceId]) async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      await _sendLocation(pos, codeOrDeviceId);
    } catch (e) {
      // silent fail
    }
  }

  // ================= SYNC OFFLINE DATA =================

  Future<void> syncOfflineLocations(String code) async {
    try {
      final db = FirebaseFirestore.instance;
      final locations = await OfflineLocationService.getLocations();

      if (locations.isEmpty) return;

      for (var loc in locations) {
        await db.collection('device_codes').doc(code).set({
          'lastLocation': {
            'lat': loc['latitude'],
            'lng': loc['longitude'],
            'updatedAt': FieldValue.serverTimestamp(),
          }
        }, SetOptions(merge: true));
      }

      await OfflineLocationService.clearLocations();
    } catch (e) {
      // keep for retry
    }
  }
}