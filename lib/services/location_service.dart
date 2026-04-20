import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'offline_location_service.dart';

class LocationService {

  static StreamSubscription<Position>? _positionStream;

  // ================= START CONTINUOUS TRACKING =================

  void startTracking(String deviceId) async {

    // Prevent multiple streams
    if (_positionStream != null) return;

    try {

      // Check service
      if (!await Geolocator.isLocationServiceEnabled()) return;

      // Permissions
      LocationPermission perm = await Geolocator.checkPermission();

      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {

        perm = await Geolocator.requestPermission();

        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          return;
        }
      }

      // Start listening
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 10, // update every 10 meters
        ),
      ).listen((Position pos) {

        _sendLocation(pos);

      });

    } catch (e) {
      // silent fail
    }
  }

  // ================= STOP TRACKING =================

  void stopTracking() {
    _positionStream?.cancel();
    _positionStream = null;
  }

  // ================= SEND LOCATION =================

  Future<void> _sendLocation(Position pos) async {

    try {

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final db = FirebaseFirestore.instance;

      final userDoc =
          await db.collection('users').doc(uid).get();

      if (!userDoc.exists) return;

      final uniqueCode = userDoc.data()?['uniqueCode'];
      if (uniqueCode == null) return;

      try {

        await db
            .collection('device_codes')
            .doc(uniqueCode)
            .set({
          'lastLocation': {
            'lat': pos.latitude,
            'lng': pos.longitude,
            'accuracy': pos.accuracy,
            'updatedAt': FieldValue.serverTimestamp(),
          }
        }, SetOptions(merge: true));

        // Sync offline queue
        await syncOfflineLocations(uniqueCode);

      } catch (e) {

        // Save offline
        await OfflineLocationService.saveLocation(
          pos.latitude,
          pos.longitude,
        );
      }

    } catch (e) {
      // silent fail
    }
  }

  // ================= SINGLE UPDATE (OPTIONAL) =================

  Future<void> updateLocation(String deviceId) async {

    try {

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );

      await _sendLocation(pos);

    } catch (e) {
      // silent fail
    }
  }

  // ================= SYNC OFFLINE DATA =================

  Future<void> syncOfflineLocations(String code) async {

    try {

      final db = FirebaseFirestore.instance;

      final locations =
          await OfflineLocationService.getLocations();

      if (locations.isEmpty) return;

      for (var loc in locations) {

        await db
            .collection('device_codes')
            .doc(code)
            .set({
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