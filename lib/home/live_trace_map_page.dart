import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class LiveTraceMapPage extends StatefulWidget {
  final String ownerUid;
  final String deviceId;

  const LiveTraceMapPage({
    super.key,
    required this.ownerUid,
    required this.deviceId,
  });

  @override
  State<LiveTraceMapPage> createState() => _LiveTraceMapPageState();
}

class _LiveTraceMapPageState extends State<LiveTraceMapPage> {
  LatLng? deviceLocation;
  LatLng? myLocation;
  StreamSubscription? sub;
  double? distanceKm;

  double _deg(double d) => d * pi / 180;

  double _distance(LatLng a, LatLng b) {
    const r = 6371;
    final dLat = _deg(b.latitude - a.latitude);
    final dLon = _deg(b.longitude - a.longitude);
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg(a.latitude)) *
            cos(_deg(b.latitude)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return r * 2 * atan2(sqrt(h), sqrt(1 - h));
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() async {
    final pos = await Geolocator.getCurrentPosition();
    myLocation = LatLng(pos.latitude, pos.longitude);

    sub = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.ownerUid)
        .collection('devices')
        .doc(widget.deviceId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists || doc['location'] == null) return;

      final lat = doc['location']['lat'];
      final lng = doc['location']['lng'];
      final newLoc = LatLng(lat, lng);

      setState(() {
        deviceLocation = newLoc;
        if (myLocation != null) {
          distanceKm = _distance(myLocation!, newLoc);
        }
      });
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (deviceLocation == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Live Device Location")),
      body: Column(
        children: [
          if (distanceKm != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                "Distance: ${distanceKm! < 1 ? "${(distanceKm! * 1000).toStringAsFixed(0)} m" : "${distanceKm!.toStringAsFixed(2)} km"}",
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: deviceLocation!,
                initialZoom: 16,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: deviceLocation!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.red,
                        size: 40,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
