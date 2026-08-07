import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';

import '../services/permission_service.dart';
import '../services/background_service.dart';
import '../services/theft_detection_service.dart';
import '../services/movement_prediction_service.dart';
import '../services/environment_scanner_service.dart';
import 'security_timeline_page.dart';

class TracePage extends StatefulWidget {
  final String? initialCode;
  const TracePage({super.key, this.initialCode});

  @override
  State<TracePage> createState() => _TracePageState();
}

class _TracePageState extends State<TracePage> {
  final TextEditingController _controller = TextEditingController();

  StreamSubscription<Position>? _myLocSub;
  StreamSubscription<DocumentSnapshot>? _deviceCodeSub;
  StreamSubscription<DocumentSnapshot>? _commandSub;
  StreamSubscription<QuerySnapshot>? _locationHistorySub;

  bool _myLocationStreamStarting = false;
  final MapController _mapController = MapController();

  LatLng? lostDevice;
  LatLng? myLocation;
  LatLng? animatedDevice;
  Timer? _animationTimer;

  bool isLoading = true;
  double? distance; // distance in meters
  String? direction;
  double? lostAccuracy;
  int? lostBattery;
  DateTime? lostUpdatedAt;
  double? lostSpeed;
  double? lostHeading;

  String statusMessage = "Checking your location...";
  bool isLost = false;
  bool isLastKnownLocation = false;
  String deviceStateText = "Offline";

  // Security & Theft Engine State
  int riskScore = 0;
  List<String> riskFactors = [];
  String theftStatus = "Normal";
  String? cellTowerInfoText;

  // Feature 8: Remote Play Sound Command state
  bool isPlaySoundActive = false;
  String commandStatus = "idle";
  bool isSendingCommand = false;

  // AI Movement Prediction tracing state
  bool isTracingActive = false;
  bool firstLocationReceived = false;
  final List<LatLng> _locationHistoryPoints = [];

  // Feature 6 & 7: Distance Alert Tracking
  final Set<int> _triggeredAlertRanges = {};
  bool _hasTriggered500mSoundAlert = false;

  List<LatLng> path = [];
  bool autoFollow = true;
  final Distance _distanceCalc = const Distance();

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
    _resetTrackingState();
    _trace();
  }

  void _resetTrackingState() {
    path.clear();
    lostDevice = null;
    animatedDevice = null;
    distance = null;
    direction = null;
    lostAccuracy = null;
    lostBattery = null;
    lostUpdatedAt = null;
    lostSpeed = null;
    lostHeading = null;
    isLastKnownLocation = false;
    deviceStateText = "Offline";
    isTracingActive = false;
    firstLocationReceived = false;
    _locationHistoryPoints.clear();
    _triggeredAlertRanges.clear();
    _hasTriggered500mSoundAlert = false;
  }

  @override
  void dispose() {
    _controller.dispose();
    _myLocSub?.cancel();
    _deviceCodeSub?.cancel();
    _commandSub?.cancel();
    _locationHistorySub?.cancel();
    _animationTimer?.cancel();
    super.dispose();
  }

  // ================= 1. LIVE LOCATION (CURRENT DEVICE) =================

  Future<void> _initMyLocationStream() async {
    if (_myLocationStreamStarting || _myLocSub != null) return;
    _myLocationStreamStarting = true;

    if (!kIsWeb) {
      bool ok = await PermissionService.requestLocationPermissionsProperly();
      if (!ok) {
        if (mounted) {
          setState(() {
            isLoading = false;
            statusMessage = "Permission Denied";
          });
        }
        _myLocationStreamStarting = false;
        return;
      }
    }

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            isLoading = false;
            statusMessage = "Please turn ON GPS";
          });
        }
        _myLocationStreamStarting = false;
        return;
      }

      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
        ).timeout(const Duration(seconds: 3));
        if (mounted) {
          setState(() {
            myLocation = LatLng(pos.latitude, pos.longitude);
            isLoading = false;
            statusMessage = "Ready. Enter device code.";
            _recalcDistanceAndDirection();
          });
        }
      } catch (_) {}

      _myLocSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        ),
      ).listen(
        (Position pos) {
          if (!mounted) return;
          setState(() {
            myLocation = LatLng(pos.latitude, pos.longitude);

            if (isLoading) {
              isLoading = false;
              statusMessage = "Ready. Enter device code.";
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (myLocation != null) {
                  _mapController.move(myLocation!, 16.0);
                }
              });
            }

            _recalcDistanceAndDirection();
          });
        },
        onError: (e) {
          if (mounted) {
            setState(() => statusMessage = "GPS signal weak/offline");
          }
        },
      );
      _myLocationStreamStarting = false;
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
          statusMessage = "Location Error";
        });
      }
      _myLocationStreamStarting = false;
    }
  }

  // ================= 2. TRACE DEVICE LOGIC =================

  Future<void> _trace() async {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) return;

    setState(() {
      statusMessage = "Verifying device code...";
      _resetTrackingState();
    });

    _deviceCodeSub?.cancel();
    _commandSub?.cancel();
    _locationHistorySub?.cancel();

    try {
      final doc = await FirebaseFirestore.instance
          .collection('device_codes')
          .doc(code)
          .get();

      if (!doc.exists) {
        setState(() => statusMessage = "Invalid Device Code");
        return;
      }

      final data = doc.data();
      if (data == null) {
        setState(() => statusMessage = "Corrupted device data");
        return;
      }

      final ownerUid = data['ownerUid']?.toString();
      final deviceId = data['deviceId']?.toString();

      await doc.reference.set({
        'isLost': true,
        'traceRequestedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Dispatch immediate high-accuracy location ping command to lost device
      await EnvironmentScannerService.requestLocationPing(code);

      isLost = true;
      isTracingActive = true;

      _listenFromDeviceCode(code);
      _listenToCommands(code);

      if (ownerUid != null && deviceId != null) {
        _listenToHistoryFallback(ownerUid, deviceId);
      }

      if (mounted) {
        setState(() {
          statusMessage = "Tracing active. Connecting to device...";
        });
      }
    } catch (e) {
      if (mounted) setState(() => statusMessage = "Unexpected Error");
    }
  }

  // ================= 3. REAL-TIME FIRESTORE LISTENER =================

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

        // Parse root fields or fallback nested lastLocation
        final double? rootLat = (data['latitude'] as num?)?.toDouble();
        final double? rootLng = (data['longitude'] as num?)?.toDouble();

        final lastLocation = data['lastLocation'];
        final double? nestedLat = (lastLocation?['lat'] as num?)?.toDouble();
        final double? nestedLng = (lastLocation?['lng'] as num?)?.toDouble();

        final double? lat = rootLat ?? nestedLat;
        final double? lng = rootLng ?? nestedLng;

        final double? accuracy = (data['accuracy'] as num?)?.toDouble() ??
            (data['gpsAccuracy'] as num?)?.toDouble() ??
            (lastLocation?['accuracy'] as num?)?.toDouble();

        final int? battery = (data['batteryLevel'] as num?)?.toInt() ??
            (data['battery'] as num?)?.toInt() ??
            (lastLocation?['battery'] as num?)?.toInt();

        final double? speed = (data['speed'] as num?)?.toDouble() ??
            (lastLocation?['speed'] as num?)?.toDouble();

        final double? heading = (data['heading'] as num?)?.toDouble() ??
            (lastLocation?['heading'] as num?)?.toDouble();

        final bool isOnlineDoc = data['isOnline'] == true;
        final bool isLocEnabledDoc = data['isLocationEnabled'] != false;

        final rawTimestamp = lastLocation?['updatedAt'] ??
            data['timestamp'] ??
            data['lastSeen'] ??
            data['updatedAt'];

        final DateTime? updatedAt = rawTimestamp is Timestamp
            ? rawTimestamp.toDate()
            : null;

        final now = DateTime.now();
        bool localLastKnown = false;
        String computedStatusText = "Online";

        if (!isLocEnabledDoc) {
          computedStatusText = "GPS Disabled";
          localLastKnown = true;
        } else if (isOnlineDoc || (updatedAt != null && now.difference(updatedAt).inMinutes < 5)) {
          computedStatusText = "Online";
          localLastKnown = false;
        } else {
          final ageText = _formatRelativeAge(updatedAt);
          computedStatusText = "Offline ($ageText)";
          localLastKnown = true;
        }

        // Feature 4: Preserve Last Known Location if coordinates exist
        if (lat != null && lng != null) {
          if (accuracy != null && accuracy > 500) {
            debugPrint("⚠️ Ignored low accuracy fix: $accuracy");
            return;
          }

          final newPos = LatLng(lat, lng);

          // Anti-GPS Jump filter (> 100km single jump)
          if (lostDevice != null) {
            final jump = _distanceCalc.as(LengthUnit.Meter, lostDevice!, newPos);
            if (jump > 100000) {
              debugPrint("🚫 Massive GPS jump ignored: $jump m");
              return;
            }
          }

          final evalResult = TheftDetectionService.evaluateDocData(data);
          final Map<String, dynamic>? cInfo = data['cellTowerInfo'] as Map<String, dynamic>?;

          if (mounted) {
            setState(() {
              _animateMarker(newPos);
              lostDevice = newPos;
              lostAccuracy = accuracy;
              lostBattery = battery;
              lostUpdatedAt = updatedAt;
              lostSpeed = speed;
              lostHeading = heading;
              isLastKnownLocation = localLastKnown;
              deviceStateText = computedStatusText;
              firstLocationReceived = true;

              if (_locationHistoryPoints.isEmpty || _locationHistoryPoints.last != newPos) {
                _locationHistoryPoints.add(newPos);
              }

              riskScore = evalResult.score;
              riskFactors = evalResult.factors;
              theftStatus = evalResult.status;
              if (cInfo != null && cInfo['cellId'] != null && (cInfo['cellId'] as num) != -1) {
                cellTowerInfoText = "Cell ID: ${cInfo['cellId']}, LAC: ${cInfo['lac']} (${cInfo['signalStrengthDbm'] ?? -113} dBm)";
              } else {
                cellTowerInfoText = null;
              }

              statusMessage = localLastKnown
                  ? "Last Known Location ($computedStatusText)"
                  : "Live tracking active";

              _recalcDistanceAndDirection();

              if (autoFollow && lostDevice != null) {
                _mapController.move(lostDevice!, 16.0);
              }
            });
          }
        } else {
          if (mounted) {
            setState(() {
              deviceStateText = computedStatusText;
              statusMessage = "Waiting for device GPS coordinates...";
            });
          }
        }
      },
      onError: (e) {
        debugPrint("🔥 device_codes error: $e");
      },
    );
  }

  // ================= 4. COMMAND LISTENER (REMOTE PLAY SOUND) =================

  void _listenToCommands(String code) {
    _commandSub?.cancel();

    _commandSub = FirebaseFirestore.instance
        .collection('device_commands')
        .doc(code)
        .snapshots()
        .listen(
      (doc) {
        if (!doc.exists) return;
        final data = doc.data();
        if (data == null) return;

        final bool playSound = data['playSound'] == true;
        final bool stopSound = data['stopSound'] == true;
        final String command = data['command']?.toString() ?? "";
        final String status = data['status']?.toString() ?? "idle";

        bool active = false;
        if (stopSound || command == 'stop_alarm' || status == 'stopped') {
          active = false;
        } else if (playSound || command == 'alarm' || status == 'playing') {
          active = true;
        }

        if (mounted) {
          setState(() {
            isPlaySoundActive = active;
            commandStatus = status;
          });
        }
      },
      onError: (e) => debugPrint("Command stream error: $e"),
    );
  }

  void _listenToHistoryFallback(String ownerUid, String deviceId) {
    _locationHistorySub?.cancel();

    _locationHistorySub = FirebaseFirestore.instance
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
        if (lostDevice != null) return; // Primary doc listener already active

        final data = snapshot.docs.first.data();
        final double? lat = (data['lat'] as num?)?.toDouble();
        final double? lng = (data['lng'] as num?)?.toDouble();
        final double? accuracy = (data['accuracy'] as num?)?.toDouble();
        final int? battery = (data['battery'] as num?)?.toInt();
        final rawTs = data['timestamp'];
        final DateTime? ts = rawTs is Timestamp ? rawTs.toDate() : null;

        if (lat != null && lng != null) {
          final pos = LatLng(lat, lng);
          if (mounted) {
            setState(() {
              lostDevice = pos;
              animatedDevice = pos;
              lostAccuracy = accuracy;
              lostBattery = battery;
              lostUpdatedAt = ts;
              isLastKnownLocation = true;
              deviceStateText = "Last Known Location";
              statusMessage = "Last Known Location";
              _recalcDistanceAndDirection();
            });
          }
        }
      },
    );
  }

  // ================= 5. MARKER ANIMATION =================

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
    _animationTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      currentStep++;
      final lat =
          start.latitude + (newPosition.latitude - start.latitude) * (currentStep / steps);
      final lng =
          start.longitude + (newPosition.longitude - start.longitude) * (currentStep / steps);
      if (mounted) setState(() => animatedDevice = LatLng(lat, lng));
      if (currentStep >= steps) timer.cancel();
    });
  }

  // ================= 6. RECALCULATE DISTANCE & DIRECTION =================

  void _recalcDistanceAndDirection() {
    if (lostDevice == null || myLocation == null) return;

    final meters = Geolocator.distanceBetween(
      myLocation!.latitude,
      myLocation!.longitude,
      lostDevice!.latitude,
      lostDevice!.longitude,
    );

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

    final dirText = dirs[((bearing + 22.5) ~/ 45) % 8];
    final bearingDeg = ((bearing + 360) % 360).toStringAsFixed(0);

    setState(() {
      distance = meters;
      direction = "$dirText ($bearingDeg°)";
      path = [myLocation!, lostDevice!];
    });

    // Feature 6 & 7: Check Distance Alerts
    _checkDistanceAlerts(meters);
  }

  // ================= 7. DISTANCE ALERTS & AUTO SOUND ALERT =================

  void _checkDistanceAlerts(double meters) {
    const thresholds = [500, 200, 100, 50, 10, 5, 1];

    for (final t in thresholds) {
      if (meters <= t && !_triggeredAlertRanges.contains(t)) {
        _triggeredAlertRanges.add(t);

        final alertMsg = "Lost device is within $t meters";
        _showMsg(alertMsg);
        BackgroundTracking.playLocalNotificationSound();
      } else if (meters > t + 20) {
        _triggeredAlertRanges.remove(t);
      }
    }

    // Feature 7: Automatic Sound Alert at 500m (once per approach)
    if (meters <= 500 && !_hasTriggered500mSoundAlert) {
      _hasTriggered500mSoundAlert = true;
      BackgroundTracking.playLocalNotificationSound();
      _showMsg("Approach Alert: Lost device is within 500 meters!");
    } else if (meters > 550) {
      _hasTriggered500mSoundAlert = false;
    }
  }

  // ================= 8. REMOTE PLAY SOUND ACTION =================

  Future<void> _toggleRemotePlaySound() async {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) {
      _showMsg("Please enter a device code first");
      return;
    }

    setState(() => isSendingCommand = true);

    try {
      final newPlayState = !isPlaySoundActive;
      await BackgroundTracking.sendPlaySoundCommand(code, newPlayState);

      if (mounted) {
        setState(() {
          isPlaySoundActive = newPlayState;
          isSendingCommand = false;
        });

        _showMsg(
          newPlayState
              ? "🔊 Playing loud alarm on lost device..."
              : "🔇 Alarm stop command sent.",
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => isSendingCommand = false);
        _showMsg("Failed to send sound command");
      }
    }
  }

  // ================= HELPERS =================

  String _formatDistance(double? meters) {
    if (meters == null) return "Calculating...";
    if (meters < 15) {
      return "${meters.toStringAsFixed(1)} m";
    } else if (meters < 1000) {
      return "${meters.toStringAsFixed(0)} m";
    } else {
      return "${(meters / 1000).toStringAsFixed(2)} km";
    }
  }

  String _formatRelativeAge(DateTime? updatedAt) {
    if (updatedAt == null) return "Unknown";
    final age = DateTime.now().difference(updatedAt);
    if (age.inSeconds < 60) return "${age.inSeconds}s ago";
    if (age.inMinutes < 60) return "${age.inMinutes}m ago";
    if (age.inHours < 24) return "${age.inHours}h ago";
    return "${age.inDays}d ago";
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ================= UI BUILD =================

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

    final initialMapCenter = lostDevice ?? myLocation ?? const LatLng(20.5937, 78.9629);

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
          // CODE SEARCH BAR
          Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 25),
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
                    color: Colors.black.withValues(alpha: 0.1),
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
                  // LAST KNOWN LOCATION / LIVE STATUS BANNER
                  if (lostDevice != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: isLastKnownLocation
                            ? Colors.orange.withValues(alpha: 0.15)
                            : Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isLastKnownLocation ? Colors.orange : Colors.green,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isLastKnownLocation ? Icons.history : Icons.gavel_rounded,
                            color: isLastKnownLocation ? Colors.orange.shade800 : Colors.green.shade800,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              isLastKnownLocation
                                  ? "LAST KNOWN LOCATION ($deviceStateText)"
                                  : "LIVE LOCATION ACTIVE",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: isLastKnownLocation
                                    ? Colors.orange.shade900
                                    : Colors.green.shade900,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 15),
                  ],

                  // SMART THEFT RISK SCORE CARD
                  _buildTheftRiskCard(isDark),

                  // MOVEMENT PREDICTION CARD
                  _buildMovementPredictionCard(isDark),

                  // CELL TOWER FALLBACK BANNER (IF GPS DISABLED)
                  if (cellTowerInfoText != null) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.cell_tower, color: Colors.amber, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "Cell Tower Triangulation Fallback: $cellTowerInfoText",
                              style: const TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // LIVE REMOTE COMMAND STATUS INDICATOR
                  _buildLiveCommandStatus(isDark),

                  // SECURITY & SCANNER ACTIONS
                  _buildSecurityActions(isDark),

                  // CAPTURED PHOTOS GALLERY
                  _buildCapturedGallerySection(isDark),

                  // LATEST AUDIO RECORDING
                  _buildLatestAudioSection(isDark),

                  // WIFI & BLUETOOTH ENVIRONMENT SCANS
                  _buildScansSection(isDark),

                  _buildInfoCard(isDark),
                  const SizedBox(height: 20),

                  // REMOTE PLAY SOUND BUTTON (FEATURE 8)
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton.icon(
                      onPressed: isSendingCommand ? null : _toggleRemotePlaySound,
                      icon: isSendingCommand
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              isPlaySoundActive ? Icons.volume_off : Icons.volume_up,
                              color: Colors.white,
                            ),
                      label: Text(
                        isPlaySoundActive
                            ? "STOP ALARM (Ringing...)"
                            : "PLAY SOUND (Loud Alarm)",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isPlaySoundActive ? Colors.red : const Color(0xff1A56DB),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                        elevation: isPlaySoundActive ? 6 : 2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // LIVE MAP (FEATURE 3, 9, 12)
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
                          color: Colors.black.withValues(alpha: 0.1),
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
                                "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
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
                                    segments: const [12.0, 12.0],
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
                                          borderRadius: BorderRadius.circular(4),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black26,
                                              blurRadius: 4,
                                            )
                                          ],
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
                                          borderRadius: BorderRadius.circular(4),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black26,
                                              blurRadius: 4,
                                            )
                                          ],
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

                  // GET DIRECTIONS BUTTON
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

  // INFO CARD COMPONENT (FEATURE 12)
  Widget _buildInfoCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xff1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "DEVICE & TRACKING INFORMATION",
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
            "Lost Device Status",
            deviceStateText,
            isLastKnownLocation ? Colors.orange : Colors.green,
          ),
          const Divider(height: 20),

          _infoTile(
            isDark,
            Icons.person_pin,
            "Current Device Status",
            myLocation != null ? "GPS Active" : "Searching GPS...",
            myLocation != null ? Colors.blue : Colors.orange,
          ),
          const Divider(height: 20),

          _infoTile(
            isDark,
            Icons.straighten,
            "Distance",
            _formatDistance(distance),
            isDark ? Colors.white : Colors.black87,
          ),
          const Divider(height: 20),

          _infoTile(
            isDark,
            Icons.gps_fixed,
            "GPS Accuracy",
            lostAccuracy != null
                ? "± ${lostAccuracy!.toStringAsFixed(0)} m"
                : "Waiting...",
            const Color(0xff1A56DB),
          ),
          const Divider(height: 20),

          _infoTile(
            isDark,
            Icons.update,
            "Last Updated Time",
            _formatRelativeAge(lostUpdatedAt),
            isDark ? Colors.white : Colors.black87,
          ),
          const Divider(height: 20),

          _infoTile(
            isDark,
            Icons.battery_full,
            "Battery Level",
            lostBattery != null ? "$lostBattery%" : "Waiting...",
            isDark ? Colors.white : Colors.black87,
          ),
          const Divider(height: 20),

          _infoTile(
            isDark,
            Icons.explore_outlined,
            "Live Direction",
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
                ? Colors.blue.withValues(alpha: 0.1)
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

  Widget _buildTheftRiskCard(bool isDark) {
    final bool isHigh = riskScore >= 50;
    final color = isHigh ? Colors.redAccent : (riskScore >= 25 ? Colors.orange : Colors.green);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xff1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.1), blurRadius: 10),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.shield, color: color, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    "AI THEFT RISK SCORE",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.blueGrey,
                      fontSize: 11,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "Risk: $riskScore%",
                  style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (riskScore / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.grey.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (riskFactors.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: riskFactors.map((factor) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.warning_amber, size: 12, color: Colors.redAccent),
                      const SizedBox(width: 4),
                      Text(
                        factor,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMovementPredictionCard(bool isDark) {
    final bool showCard = isTracingActive && firstLocationReceived;

    return AnimatedSize(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 350),
        opacity: showCard ? 1.0 : 0.0,
        child: showCard
            ? Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xff1E1E1E) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.indigoAccent.withValues(alpha: 0.3)),
                  boxShadow: [
                    BoxShadow(color: Colors.indigoAccent.withValues(alpha: 0.05), blurRadius: 10),
                  ],
                ),
                child: _buildMovementPredictionContent(isDark),
              )
            : const SizedBox(width: double.infinity, height: 0),
      ),
    );
  }

  Widget _buildMovementPredictionContent(bool isDark) {
    final pred = MovementPredictionService.predictMovement(
      currentPos: lostDevice,
      speedMs: lostSpeed ?? 0.0,
      headingDeg: lostHeading ?? 0.0,
      isOnline: !deviceStateText.contains("Offline"),
      historyCount: _locationHistoryPoints.length,
    );

    if (pred.state == PredictionState.offline) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.alt_route_rounded, color: Colors.grey, size: 20),
              SizedBox(width: 8),
              Text(
                "AI MOVEMENT PREDICTION",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            "Prediction unavailable.",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.redAccent,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Lost device is offline.",
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12),
          ),
        ],
      );
    }

    if (pred.state == PredictionState.collectingData) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.alt_route_rounded, color: Colors.amber, size: 20),
              SizedBox(width: 8),
              Text(
                "AI MOVEMENT PREDICTION",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            "Collecting movement data...",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.amber,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Please wait while enough location history is gathered.",
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12),
          ),
        ],
      );
    }

    if (pred.state == PredictionState.stationary) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.alt_route_rounded, color: Colors.indigoAccent, size: 20),
              SizedBox(width: 8),
              Text(
                "AI MOVEMENT PREDICTION",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  "Likely Moving Towards:\nStationary / Paused",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.indigoAccent,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.indigoAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  "${pred.confidencePercentage}% Confidence",
                  style: const TextStyle(
                    color: Colors.indigoAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "Reason: Device has not moved recently.",
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: const [
            Icon(Icons.alt_route_rounded, color: Colors.indigoAccent, size: 20),
            SizedBox(width: 8),
            Text(
              "AI MOVEMENT PREDICTION",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                "Likely Moving Towards:\n${pred.destination}",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.indigoAccent,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.indigoAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                "${pred.confidencePercentage}% Confidence",
                style: const TextStyle(
                  color: Colors.indigoAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          pred.description,
          style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildSecurityActions(bool isDark) {
    final code = _controller.text.trim().toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    if (code.isEmpty) {
                      _showMsg("Please enter a device code first");
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SecurityTimelinePage(deviceCode: code),
                      ),
                    );
                  },
                  icon: const Icon(Icons.timeline, color: Colors.white, size: 18),
                  label: const Text("Security Timeline", style: TextStyle(color: Colors.white, fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xff1A56DB),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    if (code.isEmpty) {
                      _showMsg("Please enter a device code first");
                      return;
                    }
                    EnvironmentScannerService.requestAudioRecording(code);
                    _showMsg("🔊 30-Second audio recording requested!");
                  },
                  icon: const Icon(Icons.mic, color: Colors.white, size: 18),
                  label: const Text("Record 30s Audio", style: TextStyle(color: Colors.white, fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    if (code.isEmpty) {
                      _showMsg("Please enter a device code first");
                      return;
                    }
                    EnvironmentScannerService.requestWifiScan(code);
                    EnvironmentScannerService.requestBluetoothScan(code);
                    _showMsg("📡 Environment WiFi/Bluetooth scan requested!");
                  },
                  icon: const Icon(Icons.wifi_find, color: Color(0xff1A56DB), size: 18),
                  label: const Text("Scan WiFi / BT", style: TextStyle(color: Color(0xff1A56DB), fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: const BorderSide(color: Color(0xff1A56DB)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    if (code.isEmpty) {
                      _showMsg("Please enter a device code first");
                      return;
                    }
                    EnvironmentScannerService.requestCameraCapture(code);
                    _showMsg("📸 Silent Front Camera photo requested!");
                  },
                  icon: const Icon(Icons.camera_alt, color: Color(0xff1A56DB), size: 18),
                  label: const Text("Capture Photo", style: TextStyle(color: Color(0xff1A56DB), fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: const BorderSide(color: Color(0xff1A56DB)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLiveCommandStatus(bool isDark) {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot>(
      stream: EnvironmentScannerService.streamCommandStatus(code),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null) return const SizedBox.shrink();

        final status = data['status']?.toString() ?? 'idle';
        final command = data['command']?.toString() ?? '';
        final reason = data['failureReason']?.toString();

        final playSound = data['playSound'] == true;

        if ((status == 'idle' && !playSound) || (command.isEmpty && !playSound)) {
          return const SizedBox.shrink();
        }

        Color badgeColor;
        IconData badgeIcon;
        String statusText;

        switch (status) {
          case 'pending':
            badgeColor = Colors.amber;
            badgeIcon = Icons.hourglass_top_rounded;
            statusText = "Pending... Dispatching to Lost Device";
            break;
          case 'running':
            badgeColor = Colors.blue;
            badgeIcon = Icons.sync_rounded;
            statusText = "Running on Lost Device...";
            break;
          case 'playing':
            badgeColor = Colors.green;
            badgeIcon = Icons.volume_up_rounded;
            statusText = "🔊 Loud Alarm Ringing on Lost Device!";
            break;
          case 'stopped':
            badgeColor = Colors.grey;
            badgeIcon = Icons.volume_off_rounded;
            statusText = "🔇 Alarm Stopped";
            break;
          case 'completed':
            badgeColor = Colors.green;
            badgeIcon = Icons.check_circle_rounded;
            statusText = "Command Completed";
            break;
          case 'failed':
            badgeColor = Colors.red;
            badgeIcon = Icons.error_rounded;
            statusText = "Command Failed${reason != null ? ': $reason' : ''}";
            break;
          default:
            if (playSound) {
              badgeColor = Colors.green;
              badgeIcon = Icons.volume_up_rounded;
              statusText = "🔊 Loud Alarm Ringing on Lost Device!";
            } else {
              return const SizedBox.shrink();
            }
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 15),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Icon(badgeIcon, color: badgeColor, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Command ($command): $statusText",
                  style: TextStyle(
                    color: badgeColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCapturedGallerySection(bool isDark) {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: EnvironmentScannerService.streamPhotos(code),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }

        final docs = snapshot.data!.docs;

        return Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xff1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.photo_library_rounded, color: Color(0xff1A56DB), size: 18),
                      SizedBox(width: 8),
                      Text(
                        "CAPTURED PHOTOS GALLERY",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                          fontSize: 11,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    "${docs.length} Photos",
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 110,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final docId = docs[index].id;
                    final imageUrl = data['imageUrl']?.toString() ?? '';

                    if (imageUrl.isEmpty) return const SizedBox.shrink();

                    return GestureDetector(
                      onTap: () => _showPhotoDialog(imageUrl, data, docId),
                      child: Container(
                        margin: const EdgeInsets.only(right: 10),
                        width: 100,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                          image: DecorationImage(
                            image: NetworkImage(imageUrl),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPhotoDialog(String imageUrl, Map<String, dynamic> data, String docId) {
    final code = _controller.text.trim().toUpperCase();
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: InteractiveViewer(
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Padding(
                      padding: EdgeInsets.all(40),
                      child: Icon(Icons.broken_image, size: 50, color: Colors.grey),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () async {
                            final uri = Uri.parse(imageUrl);
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text("Open / Zoom"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xff1A56DB),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            await EnvironmentScannerService.deletePhoto(code, docId);
                            if (context.mounted) Navigator.pop(context);
                            _showMsg("Photo deleted");
                          },
                          icon: const Icon(Icons.delete, color: Colors.red, size: 16),
                          label: const Text("Delete", style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLatestAudioSection(bool isDark) {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: EnvironmentScannerService.streamAudioRecords(code),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }

        final doc = snapshot.data!.docs.first;
        final data = doc.data() as Map<String, dynamic>;
        final docId = doc.id;
        final audioUrl = data['audioUrl']?.toString() ?? '';

        if (audioUrl.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xff1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.deepPurple.withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(color: Colors.deepPurple.withValues(alpha: 0.05), blurRadius: 10),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Row(
                    children: [
                      Icon(Icons.mic, color: Colors.deepPurple, size: 18),
                      SizedBox(width: 8),
                      Text(
                        "LATEST AUDIO RECORDING (30s)",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                          fontSize: 11,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                  Icon(Icons.audiotrack, color: Colors.deepPurple, size: 16),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final uri = Uri.parse(audioUrl);
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        } else {
                          _showMsg("Opening audio stream...");
                        }
                      },
                      icon: const Icon(Icons.play_arrow, color: Colors.white, size: 18),
                      label: const Text("Play Audio Stream", style: TextStyle(color: Colors.white, fontSize: 13)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await EnvironmentScannerService.deleteAudio(code, docId);
                      _showMsg("Audio record deleted");
                    },
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                    label: const Text("Delete", style: TextStyle(color: Colors.red, fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildScansSection(bool isDark) {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        // WiFi Scans Stream
        StreamBuilder<QuerySnapshot>(
          stream: EnvironmentScannerService.streamWifiScans(code),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
              return const SizedBox.shrink();
            }

            final doc = snapshot.data!.docs.first;
            final data = doc.data() as Map<String, dynamic>;
            final wifiList = data['wifiNetworks'] as List<dynamic>? ?? [];

            if (wifiList.isEmpty) return const SizedBox.shrink();

            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xff1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.wifi, color: Colors.blue, size: 18),
                          SizedBox(width: 8),
                          Text(
                            "NEARBY WIFI NETWORKS",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.blueGrey,
                              fontSize: 11,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        "${wifiList.length} Networks",
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...wifiList.take(5).map((item) {
                    final map = item as Map<String, dynamic>;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.wifi_lock, size: 14, color: Colors.blue),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              map['ssid']?.toString().isNotEmpty == true
                                  ? map['ssid'].toString()
                                  : "Hidden SSID",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                          Text(
                            "${map['signalStrength']} dBm",
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        ),

        // Bluetooth Scans Stream
        StreamBuilder<QuerySnapshot>(
          stream: EnvironmentScannerService.streamBluetoothScans(code),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
              return const SizedBox.shrink();
            }

            final doc = snapshot.data!.docs.first;
            final data = doc.data() as Map<String, dynamic>;
            final btList = data['bluetoothDevices'] as List<dynamic>? ?? [];

            if (btList.isEmpty) return const SizedBox.shrink();

            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xff1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.indigo.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.bluetooth, color: Colors.indigo, size: 18),
                          SizedBox(width: 8),
                          Text(
                            "NEARBY BLUETOOTH DEVICES",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.blueGrey,
                              fontSize: 11,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        "${btList.length} Devices",
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...btList.take(5).map((item) {
                    final map = item as Map<String, dynamic>;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.bluetooth_searching, size: 14, color: Colors.indigo),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              map['deviceName']?.toString().isNotEmpty == true
                                  ? map['deviceName'].toString()
                                  : "Unknown BLE Device",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                          Text(
                            "${map['rssi']} dBm",
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
