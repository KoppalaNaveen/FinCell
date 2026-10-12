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
import '../components/offline_status_banner.dart';

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
      PermissionService.requestLocationPermissionsProperly(null, false);
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

      // 🔥 Auto-bind existing device code for any account on this device
      if (uid != null && deviceId != null) {
        final boundCode = await CodeService.ensureDeviceBoundCodeForUser(uid, deviceId!);
        if (boundCode != null && boundCode.isNotEmpty && mounted) {
          setState(() {
            uniqueCode = boundCode;
            showCode = false; // Code is hidden/masked by default on login
          });
          _listenToActiveDeviceCode(boundCode);
        }
      }

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
      LocationService().startTracking(code);
    } finally {
      _trackingStartInProgress = false;
    }
  }

  // ================= CREATE CODE FLOW =================

  Future<void> _openCreateDeviceCodeDialog() async {
    if (deviceId == null || deviceId!.isEmpty) {
      try {
        deviceId = await DeviceService.registerDevice().timeout(
          const Duration(seconds: 4),
          onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
        );
      } catch (e) {
        debugPrint("Device registration error: $e");
      }
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _CreateDeviceCodeDialog(
        deviceId: deviceId ?? "device_${DateTime.now().millisecondsSinceEpoch}",
        onCodeCreated: (newCode) async {
          final uid = FirebaseAuth.instance.currentUser?.uid;
          final prefs = await SharedPreferences.getInstance();
          if (uid != null) {
            await prefs.setString('uniqueCode', newCode);
            await prefs.setString('cached_code_$uid', newCode);
          }

          if (mounted) {
            setState(() {
              uniqueCode = newCode;
              showCode = false;
            });
            debugPrint(
              "UI Updated Successfully: uniqueCode=$newCode, showCode=false, buttonHidden=true",
            );
          }

          _listenToActiveDeviceCode(newCode);
          await _showCodeSuccessDialog(newCode);
        },
      ),
    );
  }

  Future<void> _showCodeSuccessDialog(String code) async {
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xff1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Colors.blue,
                size: 36,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Your Device Code",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Your device is registered with code:",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                vertical: 14,
                horizontal: 20,
              ),
              decoration: BoxDecoration(
                color: isDark ? Colors.black38 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.blue.withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Text(
                  code,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                    color: isDark ? Colors.white : Colors.blue.shade900,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Keep this code safe to trace this device if lost.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: const BorderSide(color: Colors.blue),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    _showMsg("Code copied");
                  },
                  icon: const Icon(Icons.copy, size: 18, color: Colors.blue),
                  label: const Text(
                    "Copy",
                    style: TextStyle(
                      color: Colors.blue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                  },
                  child: const Text(
                    "Continue",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
            : Column(
                children: [
                  const OfflineStatusBanner(),
                  Expanded(
                    child: SingleChildScrollView(
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
                                  onPressed: _openCreateDeviceCodeDialog,
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
          ],
        ),
      ),
    );
  }
}

// ================= DEDICATED DEVICE CODE CREATION DIALOG =================

class _CreateDeviceCodeDialog extends StatefulWidget {
  final String deviceId;
  final Function(String) onCodeCreated;

  const _CreateDeviceCodeDialog({
    required this.deviceId,
    required this.onCodeCreated,
  });

  @override
  State<_CreateDeviceCodeDialog> createState() => _CreateDeviceCodeDialogState();
}

class _CreateDeviceCodeDialogState extends State<_CreateDeviceCodeDialog> {
  final TextEditingController _manualController = TextEditingController();
  bool _isCreatingManual = false;
  bool _isCreatingAuto = false;
  String? _errorMessage;

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _handleManualCreate() async {
    if (_isCreatingManual || _isCreatingAuto) return;

    final rawInput = _manualController.text.trim();
    if (rawInput.isEmpty) {
      setState(() {
        _errorMessage = "Please enter a device code.";
      });
      return;
    }

    final code = rawInput.toUpperCase();
    if (!CodeService.isValidFormat(code)) {
      setState(() {
        _errorMessage = "Please enter a valid device code.";
      });
      return;
    }

    setState(() {
      _isCreatingManual = true;
      _errorMessage = null;
    });

    try {
      final res = await CodeService.createCustomCode(code, widget.deviceId).timeout(
        const Duration(seconds: 15),
        onTimeout: () => CodeResult(
          success: false,
          message: "Request timed out. Please check your internet connection.",
        ),
      );
      if (!mounted) return;

      if (!res.success) {
        setState(() {
          _errorMessage = res.message;
          _isCreatingManual = false;
        });
        return;
      }

      final createdCode = res.code ?? code;
      Navigator.of(context).pop();
      widget.onCodeCreated(createdCode);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().contains("already exists")
              ? "Device code already exists. Please choose another code."
              : "Unable to create device code. Please try again.";
          _isCreatingManual = false;
        });
      }
    }
  }

  Future<void> _handleAutoGenerate() async {
    if (_isCreatingManual || _isCreatingAuto) return;

    setState(() {
      _isCreatingAuto = true;
      _errorMessage = null;
    });

    try {
      final res = await CodeService.generateSystemCode(widget.deviceId).timeout(
        const Duration(seconds: 15),
        onTimeout: () => CodeResult(
          success: false,
          message: "Request timed out. Please check your internet connection.",
        ),
      );
      if (!mounted) return;

      if (!res.success) {
        setState(() {
          _errorMessage = res.message;
          _isCreatingAuto = false;
        });
        return;
      }

      final createdCode = res.code;
      if (createdCode == null || createdCode.isEmpty) {
        setState(() {
          _errorMessage = "Unable to create device code. Please try again.";
          _isCreatingAuto = false;
        });
        return;
      }

      Navigator.of(context).pop();
      widget.onCodeCreated(createdCode);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = "Unable to create device code. Please try again.";
          _isCreatingAuto = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLoading = _isCreatingManual || _isCreatingAuto;

    return Dialog(
      backgroundColor: isDark ? const Color(0xff1E1E1E) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      "Create Your Device Code",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                    onPressed:
                        isLoading ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                "Choose how you would like to create your device code:",
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
              const SizedBox(height: 18),

              // Error Banner (if any)
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade400, width: 1),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.redAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // OPTION A: Create Manually
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black26 : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.grey.shade300,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.edit_note_rounded,
                          color: Colors.blue,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "Enter Device Code",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _manualController,
                      enabled: !isLoading,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[a-zA-Z0-9]'),
                        ),
                        LengthLimitingTextInputFormatter(8),
                      ],
                      style: TextStyle(
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      decoration: InputDecoration(
                        hintText: "e.g. ABC123",
                        hintStyle: TextStyle(
                          color: isDark ? Colors.white38 : Colors.black38,
                          letterSpacing: 2,
                        ),
                        filled: true,
                        fillColor:
                            isDark ? const Color(0xff121212) : Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white24
                                : Colors.grey.shade400,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white24
                                : Colors.grey.shade400,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Colors.blue,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: isLoading ? null : _handleManualCreate,
                        child: _isCreatingManual
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : const Text(
                                "Create Code",
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // OR separator
              Row(
                children: [
                  Expanded(
                    child: Divider(
                      color: isDark ? Colors.white24 : Colors.grey.shade300,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      "OR",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white38 : Colors.grey.shade600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Divider(
                      color: isDark ? Colors.white24 : Colors.grey.shade300,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // OPTION B: Generate Automatically
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.blue, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    foregroundColor: Colors.blue,
                  ),
                  onPressed: isLoading ? null : _handleAutoGenerate,
                  icon: _isCreatingAuto
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.blue),
                          ),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 20),
                  label: Text(
                    _isCreatingAuto
                        ? "Generating..."
                        : "Generate Automatically",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

