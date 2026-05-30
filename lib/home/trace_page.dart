import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';

import '../services/permission_service.dart';

class TracePage extends StatefulWidget {
  final String? initialCode;
  const TracePage({super.key, this.initialCode});

  @override
  State<TracePage> createState() => _TracePageState();
}

class _TracePageState extends State<TracePage> {
  final _controller = TextEditingController();

  // 🔥 FIX: Separate streams to avoid memory leaks & nested listeners
  StreamSubscription<Position>? _myLocSub;
  StreamSubscription<DocumentSnapshot>? _codeSub;
  StreamSubscription<QuerySnapshot>? _locationSub;

  StreamSubscription<DocumentSnapshot>? _deviceCodeSub;
  bool _myLocationStreamStarting = false;

  final MapController _mapController = MapController();

  LatLng? lostDevice;
  LatLng? myLocation;

  bool isLoading = true;
  double? distance;
  String? direction;
  double? lostAccuracy;
  int? lostBattery;
  DateTime? lostUpdatedAt;
  String statusMessage = "Checking your location...";
  bool isLost = false;

  List<LatLng> path = [];
  bool autoFollow = true;
  LatLng? animatedDevice;
  Timer? _animationTimer;

  final Distance _distanceCalc = Distance();
  List<LatLng> pathPoints = [];

  @override
  void initState() {
    super.initState();
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
    );
    if (widget.initialCode != null) {
      _startTracking(widget.initialCode!);
    }
    _initMyLocationStream();
  }

  void _startTracking(String code) {
    _controller.text = code.trim().toUpperCase();

    // RESET STATE CLEANLY
    pathPoints.clear();
    path.clear();
    lostDevice = null;
    animatedDevice = null;
    distance = null;
    direction = null;
    lostAccuracy = null;
    lostBattery = null;
    lostUpdatedAt = null;

    _trace();
  }

  @override
  void dispose() {
    _controller.dispose();
    _myLocSub?.cancel();
    _codeSub?.cancel();
    _locationSub?.cancel();
    _animationTimer?.cancel();
    _deviceCodeSub?.cancel();
    super.dispose();
  }

  // ================= 1. LIVE LOCATION (YOUR DEVICE) =================

  Future<void> _initMyLocationStream() async {
    if (_myLocationStreamStarting || _myLocSub != null) return;
    _myLocationStreamStarting = true;

    if (!kIsWeb) {
      bool ok = await PermissionService.requestLocationPermissionsProperly();
      if (!ok) {
        if (mounted)
          setState(() {
            isLoading = false;
            statusMessage = "Permission Denied";
          });
        _myLocationStreamStarting = false;
        return;
      }
    }

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted)
          setState(() {
            isLoading = false;
            statusMessage = "Please turn ON GPS";
          });
        _myLocationStreamStarting = false;
        return;
      }

      // 🔥 FIX: Live stream for YOUR location (Updates as you move)
      _myLocSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 5, // Updates every 5 meters
            ),
          ).listen(
            (Position pos) {
              if (!mounted) return;
              setState(() {
                myLocation = LatLng(pos.latitude, pos.longitude);

                if (isLoading) {
                  isLoading = false;
                  statusMessage = "Ready. Enter code.";
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _mapController.move(myLocation!, 16.0);
                  });
                }

                // Recalculate route & distance dynamically as YOU move
                _recalc();
              });
            },
            onError: (e) {
              if (mounted)
                setState(() => statusMessage = "GPS signal weak/offline");
            },
          );
      _myLocationStreamStarting = false;
    } catch (e) {
      if (mounted)
        setState(() {
          isLoading = false;
          statusMessage = "Location Error";
        });
      _myLocationStreamStarting = false;
    }
  }

  // ================= 2. TRACE LOGIC (CODE -> DEVICE ID) =================

  Future<void> _trace() async {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) return;

    setState(() {
      statusMessage = "Verifying code...";

      // 🔥 RESET CLEANLY
      pathPoints.clear();
      path.clear();
      lostDevice = null;
      animatedDevice = null;
      distance = null;
      direction = null;
      lostAccuracy = null;
      lostBattery = null;
      lostUpdatedAt = null;
    });

    _codeSub?.cancel();
    _locationSub?.cancel();
    _deviceCodeSub?.cancel();

    try {
      final doc = await FirebaseFirestore.instance
          .collection('device_codes')
          .doc(code)
          .get();

      if (!doc.exists) {
        setState(() => statusMessage = "Invalid Code");
        return;
      }

      final data = doc.data();
      if (data == null) {
        setState(() => statusMessage = "Corrupted data");
        return;
      }

      final ownerUid = data['ownerUid']?.toString();
      final deviceId = data['deviceId']?.toString();

      if (ownerUid == null || deviceId == null) {
        setState(() => statusMessage = "Device mapping missing");
        return;
      }

      await doc.reference.set({
        'isLost': true,
        'traceRequestedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      isLost = true;

      // 🔥 DIRECT LISTEN
      _listenToLiveLocation(ownerUid, deviceId);
      _listenFromDeviceCode(code);

      if (mounted) {
        setState(
          () => statusMessage = "Lost mode requested. Waiting for live GPS...",
        );
      }
    } catch (e) {
      setState(() => statusMessage = "Unexpected Error");
    }
  }

  void _listenToLiveLocation(String ownerUid, String deviceId) {
    _locationSub?.cancel();

    _locationSub = FirebaseFirestore.instance
        .collection('users')
        .doc(ownerUid)
        .collection('devices')
        .doc(deviceId)
        .collection('locations')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .listen(
          (snapshot) {
            if (snapshot.docs.isEmpty) return;

            final data = snapshot.docs.first.data();

            final double? lat = (data['lat'] as num?)?.toDouble();
            final double? lng = (data['lng'] as num?)?.toDouble();
            final double? accuracy = (data['accuracy'] as num?)?.toDouble();
            final int? battery = (data['battery'] as num?)?.toInt();
            final rawTimestamp = data['timestamp'];
            final DateTime? updatedAt = rawTimestamp is Timestamp
                ? rawTimestamp.toDate()
                : null;

            debugPrint(
              "📡 Firestore → Lat:$lat Lng:$lng Acc:$accuracy Battery:$battery",
            );

            // ✅ NULL CHECK FIRST (CRITICAL)
            if (lat == null || lng == null) {
              if (mounted)
                setState(() => statusMessage = "Invalid location data");
              return;
            }

            // ✅ ACCURACY FILTER
            if (accuracy != null && accuracy > 100) {
              debugPrint("⚠️ Ignored low accuracy: $accuracy");
              return;
            }

            final newPos = LatLng(lat, lng);

            // ✅ ANTI GPS JUMP FILTER
            if (lostDevice != null) {
              final jump = _distanceCalc.as(
                LengthUnit.Meter,
                lostDevice!,
                newPos,
              );

              if (jump > 10000) {
                debugPrint("🚫 GPS jump ignored: $jump m");
                return;
              }
            }

            // ✅ PATH HISTORY
            pathPoints.add(newPos);

            if (mounted) {
              setState(() {
                _animateMarker(newPos);
                lostDevice = newPos;
                lostAccuracy = accuracy;
                lostBattery = battery;
                lostUpdatedAt = updatedAt;

                // ✅ DISTANCE CALCULATION
                if (myLocation != null) {
                  final meters = _distanceCalc.as(
                    LengthUnit.Meter,
                    myLocation!,
                    newPos,
                  );
                  distance = meters;
                }

                // ✅ STATUS
                statusMessage = _statusForFix(
                  fromCache: snapshot.metadata.isFromCache,
                  accuracy: accuracy,
                  updatedAt: updatedAt,
                );

                if (autoFollow) {
                  _mapController.move(newPos, 14.0);
                }
              });
            }
          },
          onError: (e) {
            debugPrint("🔥 Location stream error: $e");

            if (mounted) {
              setState(() {
                statusMessage = "Firestore read failed";
              });
            }
          },
        );
  }

  void _listenFromDeviceCode(String code) {
    _deviceCodeSub?.cancel();

    _deviceCodeSub = FirebaseFirestore.instance
        .collection('device_codes')
        .doc(code)
        .snapshots()
        .listen(
          (doc) {
            if (!doc.exists) return;

            final data = doc.data();
            if (data == null) return;

            isLost = data['isLost'] == true;

            final lastLocation = data['lastLocation'];

            if (lastLocation == null) {
              if (mounted) {
                setState(
                  () => statusMessage = isLost
                      ? "Lost mode requested. Waiting for device GPS..."
                      : "Waiting for device GPS...",
                );
              }
              return;
            }

            final double? lat = (lastLocation['lat'] as num?)?.toDouble();
            final double? lng = (lastLocation['lng'] as num?)?.toDouble();
            final double? accuracy = (lastLocation['accuracy'] as num?)
                ?.toDouble();
            final int? battery = (lastLocation['battery'] as num?)?.toInt();
            final rawUpdatedAt = lastLocation['updatedAt'];
            final DateTime? updatedAt = rawUpdatedAt is Timestamp
                ? rawUpdatedAt.toDate()
                : null;

            if (lat == null || lng == null) return;

            if (accuracy != null && accuracy > 100) {
              debugPrint("⚠️ Ignored low accuracy: $accuracy");
              return;
            }

            final newPos = LatLng(lat, lng);

            // 🔥 ANTI JUMP
            if (lostDevice != null) {
              final jump = _distanceCalc.as(
                LengthUnit.Meter,
                lostDevice!,
                newPos,
              );

              if (jump > 10000) {
                debugPrint("🚫 GPS jump ignored: $jump m");
                return;
              }

              // 🔥 IGNORE SMALL NOISE
              if (jump < 1) return;
            }

            // 🔥 ADD ONLY ONCE
            pathPoints.add(newPos);

            if (mounted) {
              setState(() {
                _animateMarker(newPos);
                lostDevice = newPos;
                lostAccuracy = accuracy;
                lostBattery = battery;
                lostUpdatedAt = updatedAt;

                statusMessage = _statusForFix(
                  fromCache: doc.metadata.isFromCache,
                  accuracy: accuracy,
                  updatedAt: updatedAt,
                );

                // 🔥 DISTANCE
                if (myLocation != null) {
                  distance = _distanceCalc.as(
                    LengthUnit.Meter,
                    myLocation!,
                    newPos,
                  );

                  // keep UI intact
                  path = [myLocation!, newPos];
                }

                if (autoFollow) {
                  _mapController.move(newPos, 14.0);
                }
              });
            }

            debugPrint(
              "📍 DeviceCode → Lat:$lat Lng:$lng Acc:$accuracy Battery:$battery",
            );
          },
          onError: (e) {
            debugPrint("🔥 device_codes error: $e");
          },
        );
  }

  void _animateMarker(LatLng newPosition) {
    if (animatedDevice == null) {
      animatedDevice = newPosition;
      return;
    }

    if (_animationTimer?.isActive == true) return;

    _animationTimer?.cancel();
    final start = animatedDevice!;
    int steps = 15;
    int currentStep = 0;
    _animationTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      currentStep++;
      final lat =
          start.latitude +
          (newPosition.latitude - start.latitude) * (currentStep / steps);
      final lng =
          start.longitude +
          (newPosition.longitude - start.longitude) * (currentStep / steps);
      if (mounted) setState(() => animatedDevice = LatLng(lat, lng));
      if (currentStep >= steps) timer.cancel();
    });
  }

  void _recalc() {
    if (lostDevice == null || myLocation == null) return;

    final meters = _distanceCalc.as(LengthUnit.Meter, myLocation!, lostDevice!);

    final bearing = Geolocator.bearingBetween(
      myLocation!.latitude,
      myLocation!.longitude,
      lostDevice!.latitude,
      lostDevice!.longitude,
    );

    const dirs = [
      "North",
      "North-East",
      "East",
      "South-East",
      "South",
      "South-West",
      "West",
      "North-West",
    ];

    setState(() {
      distance = meters;
      direction = dirs[((bearing + 22.5) ~/ 45) % 8];

      path = [myLocation!, lostDevice!]; // keep your UI intact
    });
  }

  Future<void> _openMaps() async {
    if (lostDevice == null) {
      _showMsg("Trace a device first");
      return;
    }
    final url =
        "https://www.google.com/maps/dir/?api=1&destination=${lostDevice!.latitude},${lostDevice!.longitude}";
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _statusForFix({
    required bool fromCache,
    required double? accuracy,
    required DateTime? updatedAt,
  }) {
    final accuracyText = accuracy == null
        ? ""
        : " (GPS +- ${accuracy.toStringAsFixed(0)} m)";

    if (fromCache) {
      return "Last known location$accuracyText";
    }

    if (updatedAt == null) {
      return "Live tracking active$accuracyText";
    }

    final age = DateTime.now().difference(updatedAt);
    if (age.inSeconds <= 30) {
      return "Live tracking active$accuracyText";
    }

    if (age.inMinutes < 60) {
      return "Last updated ${age.inMinutes} min ago$accuracyText";
    }

    return "Last updated ${age.inHours} hr ago$accuracyText";
  }

  String _formatLastUpdated(DateTime? updatedAt) {
    if (updatedAt == null) return "Waiting...";

    final age = DateTime.now().difference(updatedAt);
    if (age.inSeconds < 60) return "${age.inSeconds}s ago";
    if (age.inMinutes < 60) return "${age.inMinutes}m ago";
    if (age.inHours < 24) return "${age.inHours}h ago";
    return "${age.inDays}d ago";
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isLoading) {
      return Scaffold(
        backgroundColor: isDark
            ? const Color(0xff121212)
            : const Color(0xffF3F6FF),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xff1A56DB)),
              SizedBox(height: 15),
              Text(
                "Getting your live location...",
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    final initialMapCenter = myLocation ?? const LatLng(20.5937, 78.9629);

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xff121212)
          : const Color(0xffF3F6FF),
      appBar: AppBar(
        title: const Text(
          "Trace Lost Device",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: const Color(0xff1A56DB),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
            decoration: const BoxDecoration(
              color: Color(0xff1A56DB),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xff1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.characters,
                style: TextStyle(color: isDark ? Colors.white : Colors.black),
                decoration: InputDecoration(
                  hintText: "Enter device code (e.g. YD2NJG)",
                  hintStyle: TextStyle(
                    color: isDark ? Colors.white54 : Colors.grey,
                  ),
                  border: InputBorder.none,
                  suffixIcon: Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: ElevatedButton(
                      onPressed: _trace,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xff1A56DB),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 15),
                      ),
                      child: const Text(
                        "Trace",
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _buildInfoCard(isDark),
                  const SizedBox(height: 20),

                  Container(
                    height: 320,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xff1E1E1E) : Colors.white,
                      borderRadius: BorderRadius.circular(25),
                      border: Border.all(
                        color: isDark ? Colors.grey.shade800 : Colors.white,
                        width: 5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 15,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: initialMapCenter,
                          initialZoom: 16.0,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                "https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}",
                            userAgentPackageName: 'com.example.fincell',
                          ),

                          if (path.isNotEmpty && path.length > 1)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: path,
                                  strokeWidth: 5,
                                  color: Colors.indigoAccent,
                                  pattern: StrokePattern.dashed(
                                    segments: [12.0, 12.0],
                                  ),
                                ),
                              ],
                            ),

                          MarkerLayer(
                            markers: [
                              if (animatedDevice != null)
                                Marker(
                                  point: animatedDevice!,
                                  width: 80,
                                  height: 80,
                                  child: Column(
                                    children: [
                                      const Icon(
                                        Icons.location_on,
                                        color: Colors.red,
                                        size: 45,
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: const Text(
                                          "LOST DEVICE",
                                          style: TextStyle(
                                            fontSize: 8,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.red,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                              if (myLocation != null)
                                Marker(
                                  point: myLocation!,
                                  width: 80,
                                  height: 80,
                                  child: Column(
                                    children: [
                                      const Icon(
                                        Icons.person_pin_circle,
                                        color: Colors.blue,
                                        size: 45,
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: const Text(
                                          "YOU",
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.blue,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 25),

                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: OutlinedButton.icon(
                      onPressed: _openMaps,
                      icon: const Icon(
                        Icons.directions,
                        color: Color(0xff1A56DB),
                      ),
                      label: const Text(
                        "Get Directions in Google Maps",
                        style: TextStyle(
                          color: Color(0xff1A56DB),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                          color: Color(0xff1A56DB),
                          width: 1.5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xff1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "DEVICE INFORMATION",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 15),
          _infoTile(
            isDark,
            Icons.wifi_tethering,
            "Status",
            statusMessage,
            isLost ? Colors.red : Colors.green,
          ),
          const Divider(height: 20),
          _infoTile(
            isDark,
            Icons.gps_fixed,
            "Accuracy",
            lostAccuracy != null
                ? "+- ${lostAccuracy!.toStringAsFixed(0)} m"
                : "Waiting...",
            const Color(0xff1A56DB),
          ),
          const Divider(height: 20),
          _infoTile(
            isDark,
            Icons.update,
            "Last update",
            _formatLastUpdated(lostUpdatedAt),
            isDark ? Colors.white : Colors.black87,
          ),
          const Divider(height: 20),
          _infoTile(
            isDark,
            Icons.battery_full,
            "Battery",
            lostBattery != null ? "$lostBattery%" : "Waiting...",
            isDark ? Colors.white : Colors.black87,
          ),
          const Divider(height: 20),
          _infoTile(
            isDark,
            Icons.speed,
            "Distance",
            distance != null
                ? (distance! < 1000
                      ? "${distance!.toStringAsFixed(0)} m away"
                      : "${(distance! / 1000).toStringAsFixed(1)} km away")
                : "Calculating...",
            isDark ? Colors.white : Colors.black87,
          ),
          const Divider(height: 20),
          _infoTile(
            isDark,
            Icons.explore_outlined,
            "Direction",
            direction ?? "Detecting...",
            const Color(0xff1A56DB),
          ),
        ],
      ),
    );
  }

  Widget _infoTile(
    bool isDark,
    IconData icon,
    String title,
    String value,
    Color valueColor,
  ) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.blue.withOpacity(0.1)
                : const Color(0xffF0F4FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: const Color(0xff1A56DB), size: 18),
        ),
        const SizedBox(width: 15),
        Text(
          title,
          style: TextStyle(
            color: isDark ? Colors.white70 : Colors.grey,
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}
