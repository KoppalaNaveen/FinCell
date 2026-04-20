import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class LiveMapPage extends StatefulWidget {
  final String code;

  const LiveMapPage({super.key, required this.code});

  @override
  State<LiveMapPage> createState() => _LiveMapPageState();
}

class _LiveMapPageState extends State<LiveMapPage> {

  GoogleMapController? _mapController;

  LatLng? deviceLocation;
  LatLng? userLocation;

  double? distance;

  StreamSubscription<DocumentSnapshot>? _sub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ================= INIT =================

  Future<void> _init() async {

    await _getUserLocation();
    _listenDevice();
  }

  // ================= USER LOCATION =================

  Future<void> _getUserLocation() async {

    final pos = await Geolocator.getCurrentPosition();

    setState(() {
      userLocation = LatLng(pos.latitude, pos.longitude);
    });
  }

  // ================= DEVICE LISTENER =================

  void _listenDevice() {

    _sub = FirebaseFirestore.instance
        .collection('device_codes')
        .doc(widget.code.toUpperCase())
        .snapshots()
        .listen((doc) {

      if (!doc.exists) return;

      final data = doc.data();

      final loc = data?['lastLocation'];

      if (loc == null) return;

      final newLocation = LatLng(loc['lat'], loc['lng']);

      setState(() {
        deviceLocation = newLocation;
      });

      _calculateDistance();

      // 🔥 AUTO MOVE CAMERA
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(newLocation),
      );
    });
  }

  // ================= DISTANCE =================

  void _calculateDistance() {

    if (userLocation == null || deviceLocation == null) return;

    final d = Geolocator.distanceBetween(
      userLocation!.latitude,
      userLocation!.longitude,
      deviceLocation!.latitude,
      deviceLocation!.longitude,
    );

    setState(() {
      distance = d / 1000; // km
    });
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(title: const Text("Live Tracking")),

      body: deviceLocation == null
          ? const Center(child: Text("Waiting for device location..."))
          : Column(
              children: [

                // MAP
                Expanded(
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: deviceLocation!,
                      zoom: 15,
                    ),
                    onMapCreated: (controller) {
                      _mapController = controller;
                    },
                    markers: {

                      // DEVICE MARKER
                      Marker(
                        markerId: const MarkerId("device"),
                        position: deviceLocation!,
                        infoWindow: const InfoWindow(
                          title: "Tracked Device",
                        ),
                      ),

                      // USER MARKER
                      if (userLocation != null)
                        Marker(
                          markerId: const MarkerId("user"),
                          position: userLocation!,
                          infoWindow: const InfoWindow(
                            title: "You",
                          ),
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueAzure,
                          ),
                        ),
                    },
                  ),
                ),

                // INFO PANEL
                Container(
                  padding: const EdgeInsets.all(16),
                  width: double.infinity,
                  color: Colors.white,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      Text(
                        "Device Location:",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),

                      Text(
                        "${deviceLocation!.latitude}, ${deviceLocation!.longitude}",
                      ),

                      const SizedBox(height: 10),

                      if (distance != null)
                        Text(
                          "Distance: ${distance!.toStringAsFixed(2)} km",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.blue),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}