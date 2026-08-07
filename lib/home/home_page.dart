import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import '../services/device_service.dart';
import '../services/permission_service.dart';
import '../services/code_service.dart';
import '../services/background_service.dart';
import '../services/location_service.dart';

import 'package:flutter/foundation.dart';

import 'trace_page.dart';
import 'profile_page.dart';

class HomePage extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;

  const HomePage({super.key, required this.onThemeChanged});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String? deviceId;
  String? uniqueCode;

  bool loading = true;
  String? initError;

  bool _trackingStarted = false;
  bool _creatingCode = false;

  final LocalAuthentication auth = LocalAuthentication();
  bool showCode = false;
  Timer? hideTimer;

  StreamSubscription<DocumentSnapshot>? _userListener;
  StreamSubscription<DocumentSnapshot>? _deviceCodeListener;
  String? _observedCode;
  bool _trackingStartInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (!kIsWeb) {
      BackgroundTracking.initializeNativeListener();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initApp();
      _handlePermissions();
    });

    Future.delayed(const Duration(seconds: 1), () async {
      if (!kIsWeb && uniqueCode != null && uniqueCode!.isNotEmpty) {
        try {
          final started = await BackgroundTracking.start(uniqueCode!);
          if (started) _trackingStarted = true;
        } catch (e) {
          debugPrint("Auto-start tracking notice: $e");
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    hideTimer?.cancel();
    _userListener?.cancel();
    _deviceCodeListener?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !kIsWeb) {
      PermissionService.requestLocationPermissionsProperly(context);
    }
  }

  Future<void> _handlePermissions() async {
    if (kIsWeb) return;
    await PermissionService.setupTrackingPermissions(context);
  }

  // ================= AUTH =================

  Future<void> _authenticateAndShowCode() async {
    if (kIsWeb) {
      setState(() => showCode = true);
      hideTimer?.cancel();
      hideTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) setState(() => showCode = false);
      });
      return;
    }

    try {
      bool canAuthenticate =
          await auth.canCheckBiometrics || await auth.isDeviceSupported();

      if (!canAuthenticate) {
        _showMsg("Authentication not available");
        return;
      }

      bool authenticated = await auth.authenticate(
        localizedReason: "Authenticate to view device code",
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );

      if (authenticated) {
        setState(() => showCode = true);
        hideTimer?.cancel();
        hideTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => showCode = false);
        });
      }
    } catch (e) {
      _showMsg("Authentication unavailable");
    }
  }

  // ================= INIT =================

  Future<void> _initApp() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final prefs = await SharedPreferences.getInstance();

      final cachedCode =
          prefs.getString('uniqueCode') ??
          (uid != null ? prefs.getString('cached_code_$uid') : null);

      if (cachedCode != null && cachedCode.isNotEmpty && mounted) {
        setState(() {
          uniqueCode = cachedCode;
        });
        _listenToActiveDeviceCode(cachedCode);
      }

      deviceId = await DeviceService.registerDevice().timeout(
        const Duration(seconds: 4),
        onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
      );

      if (uid != null) {
        _userListener?.cancel();
        _userListener = FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .snapshots()
            .listen(
              (doc) async {
                if (!doc.exists || !mounted) return;

                final data = doc.data();
                final code = data?['uniqueCode'];
                final nextCode = (code != null && code.toString().isNotEmpty)
                    ? code.toString().trim().toUpperCase()
                    : null;

                if (nextCode != null) {
                  await prefs.setString('uniqueCode', nextCode);
                  await prefs.setString('cached_code_$uid', nextCode);
                }

                if (mounted) {
                  setState(() {
                    uniqueCode = nextCode;
                  });
                }

                _listenToActiveDeviceCode(nextCode);
              },
              onError: (e) {
                debugPrint("User listener error: $e");
              },
            );
      }

      unawaited(_checkSecuritySetup());
    } catch (e) {
      debugPrint("Init error: $e");
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  void _listenToActiveDeviceCode(String? code) {
    if (_observedCode == code) return;

    if (_trackingStarted && _observedCode != null && !kIsWeb) {
      unawaited(BackgroundTracking.stop(_observedCode!));
      LocationService().stopTracking();
    }

    _deviceCodeListener?.cancel();
    _observedCode = code;
    _trackingStarted = false;
    _trackingStartInProgress = false;

    if (code == null || code.isEmpty) return;

    // Start continuous tracking & command listeners for active device code
    _ensureTrackingActiveForCode(code);

    _deviceCodeListener = FirebaseFirestore.instance
        .collection('device_codes')
        .doc(code)
        .snapshots()
        .listen((doc) async {
          if (!doc.exists || !mounted) return;

          final data = doc.data();
          final isLost = data?['isLost'] == true;

          await _ensureTrackingActiveForCode(code);

          if (isLost) {
            debugPrint("🚨 Lost Mode active for: $code");
          }
        });
  }

  Future<void> _ensureTrackingActiveForCode(String code) async {
    if (_trackingStartInProgress) return;

    _trackingStartInProgress = true;

    try {
      debugPrint("Ensuring active device protection for: $code");

      if (!kIsWeb) {
        final granted = await PermissionService.setupTrackingPermissions();
        if (granted) {
          final started = await BackgroundTracking.start(code);
          if (started) {
            _trackingStarted = true;
          }
        }
      }

      // Also ensure Flutter LocationService is tracking & updating location
      LocationService().startTracking(deviceId ?? code);
    } finally {
      _trackingStartInProgress = false;
    }
  }

  // ================= CREATE CODE =================

  Future<void> _chooseCode() async {
    if (_creatingCode) return;

    debugPrint("Create Your Code button pressed");

    if (mounted) {
      setState(() => _creatingCode = true);
    }

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint("Create Code Failed: no authenticated user");
        _showMsg("Create code failed: User is not authenticated.");
        return;
      }

      final uid = user.uid;
      debugPrint("Current UID: $uid");

      if (deviceId == null || deviceId!.isEmpty) {
        debugPrint(
          "Device ID missing; registering device before code creation",
        );
        deviceId = await DeviceService.registerDevice().timeout(
          const Duration(seconds: 4),
          onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
        );
        debugPrint("Device ID resolved: $deviceId");
      }

      final res = await CodeService.generateSystemCode(deviceId!);

      if (!res.success) {
        debugPrint("Create Code Failed: ${res.message}");
        _showMsg(res.message);
        return;
      }

      final code = res.code?.trim().toUpperCase();
      if (code == null || code.isEmpty) {
        throw StateError(
          "Code service returned success without a device code.",
        );
      }

      final prefs = await SharedPreferences.getInstance();
      final savedUnique = await prefs.setString('uniqueCode', code);
      final savedUid = await prefs.setString('cached_code_$uid', code);
      debugPrint(
        "SharedPreferences Saved: uniqueCode=$savedUnique cached_code_$uid=$savedUid",
      );

      if (!savedUnique || !savedUid) {
        throw StateError("SharedPreferences returned false while saving code.");
      }

      if (mounted) {
        setState(() {
          uniqueCode = code;
        });
        debugPrint("UI Refreshed: uniqueCode=$code");
      }

      _listenToActiveDeviceCode(code);
      _showMsg(res.message);
    } catch (e, stackTrace) {
      debugPrint("Create Code Exception: $e");
      debugPrint("Stack Trace: $stackTrace");
      _showMsg("Create code failed: $e");
    } finally {
      if (mounted) {
        setState(() => _creatingCode = false);
      }
    }
  }

  Future<void> _checkSecuritySetup() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final ref = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final doc = await ref.get();
    if (!doc.exists) {
      await ref.set({
        'email': user.email,
        'securityQuestion': null,
        'securityAnswer': null,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  // ================= LOST MODE =================

  Future<void> _markLost() async {
    final controller = TextEditingController();

    final enteredCode = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Activate Lost Mode"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "Enter device code"),
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim().toUpperCase()),
            child: const Text("Activate"),
          ),
        ],
      ),
    );

    if (enteredCode == null || enteredCode.isEmpty) return;

    try {
      final code = enteredCode.trim().toUpperCase();

      final docRef = FirebaseFirestore.instance
          .collection("device_codes")
          .doc(code);

      final doc = await docRef.get();

      // ✅ CHECK ONLY EXISTENCE
      if (!doc.exists) {
        _showMsg("Invalid code");
        return;
      }

      // 🔥 MARK DEVICE AS LOST
      await docRef.set({
        "isLost": true,
        "traceRequestedAt": FieldValue.serverTimestamp(),
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;

      _showMsg("Device marked as LOST");

      // 🔥 NAVIGATE TO TRACK PAGE
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TracePage(initialCode: code)),
      );
    } catch (e) {
      debugPrint("🔥 LOST MODE ERROR: $e");
      _showMsg("Error activating Lost Mode");
    }
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final showCreateButton = uniqueCode == null || uniqueCode!.isEmpty;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xff121212)
          : const Color(0xffF4F6FA),

      floatingActionButton: FloatingActionButton(
        onPressed: () {
          widget.onThemeChanged(isDark ? ThemeMode.light : ThemeMode.dark);
        },
        backgroundColor: Colors.blue,
        child: Icon(
          isDark ? Icons.light_mode : Icons.dark_mode,
          color: Colors.white,
        ),
      ),

      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : initError != null
            ? Center(child: Text(initError!, textAlign: TextAlign.center))
            : SingleChildScrollView(
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xff3A6FE2), Color(0xff2453C5)],
                        ),
                        borderRadius: BorderRadius.only(
                          bottomLeft: Radius.circular(30),
                          bottomRight: Radius.circular(30),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "FinCell",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 5),
                              Text(
                                "Lost Device Tracker",
                                style: TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                          GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ProfilePage(
                                  onThemeChanged: widget.onThemeChanged,
                                ),
                              ),
                            ),
                            child: CircleAvatar(
                              backgroundColor: Colors.white24,
                              child: Text(
                                user.email != null && user.email!.isNotEmpty
                                    ? user.email![0].toUpperCase()
                                    : "U",
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 30),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xff1E1E1E)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(color: Colors.black12, blurRadius: 10),
                          ],
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.phone_android,
                                  color: Colors.blue,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  "YOUR DEVICE CODE",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isDark
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 15),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.black26
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    showCode ? (uniqueCode ?? "---") : "••••••",
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 3,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      IconButton(
                                        icon: Icon(
                                          showCode
                                              ? Icons.visibility_off
                                              : Icons.visibility,
                                          color: Colors.grey,
                                        ),
                                        onPressed: _authenticateAndShowCode,
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.copy,
                                          color: Colors.grey,
                                        ),
                                        onPressed:
                                            (showCode && uniqueCode != null)
                                            ? () {
                                                Clipboard.setData(
                                                  ClipboardData(
                                                    text: uniqueCode!,
                                                  ),
                                                );
                                                _showMsg("Code copied");
                                              }
                                            : null,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              "Share this code with trusted contacts",
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                            if (showCreateButton)
                              Padding(
                                padding: const EdgeInsets.only(top: 15),
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(
                                      double.infinity,
                                      45,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  onPressed: _creatingCode ? null : _chooseCode,
                                  child: const Text("Create Your Code"),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 25),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: SizedBox(
                        width: double.infinity,
                        height: 55,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _markLost,
                          icon: const Icon(Icons.warning, color: Colors.white),
                          label: const Text(
                            "Mark Device as LOST",
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 15),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: SizedBox(
                        width: double.infinity,
                        height: 55,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.blue),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const TracePage(),
                            ),
                          ),
                          icon: const Icon(
                            Icons.location_on,
                            color: Colors.blue,
                          ),
                          // 🔥 FIX: Removed 'const' from Text widget because 'isDark' is a runtime variable
                          label: Text(
                            "Trace Device Using Code",
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 50),
                  ],
                ),
              ),
      ),
    );
  }
}
