import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Directory, File;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import '../services/device_service.dart';
import '../services/code_service.dart';
import '../services/background_service.dart';
import '../services/location_service.dart';
import '../services/offline_location_service.dart';
import '../auth/auth_gate.dart';

class ProfilePage extends StatefulWidget {
  // 🔥 CRITICAL FIX: Theme change avvalante ee callback kavali
  final Function(ThemeMode)? onThemeChanged;

  const ProfilePage({super.key, this.onThemeChanged});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  User? get currentUser => FirebaseAuth.instance.currentUser;

  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final LocalAuthentication auth = LocalAuthentication();

  bool loading = true;
  bool uploadingPhoto = false;
  bool showCode = false;

  String? photoUrl;
  String? deviceId;

  StreamSubscription<DocumentSnapshot>? _userListener;
  Timer? hideTimer;
  DateTime? lastActionTime;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _userListener?.cancel();
    hideTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final user = currentUser;
      final prefs = await SharedPreferences.getInstance();

      if (user != null) {
        final cachedCode =
            prefs.getString('uniqueCode') ??
            prefs.getString('cached_code_${user.uid}');
        if (cachedCode != null && cachedCode.isNotEmpty) {
          _codeController.text = cachedCode;
        }
        if (user.displayName != null && user.displayName!.isNotEmpty) {
          _nameController.text = user.displayName!;
        }
      }

      _listenUser();

      // Ensure loading is dismissed after max 1 second
      Timer(const Duration(milliseconds: 1000), () {
        if (mounted && loading) {
          setState(() => loading = false);
        }
      });

      try {
        deviceId = await DeviceService.registerDevice().timeout(
          const Duration(seconds: 3),
          onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
        );
      } catch (e) {
        debugPrint("Device registration notice: $e");
      }
    } catch (e) {
      debugPrint("Profile init error: $e");
    } finally {
      if (mounted && loading) {
        setState(() => loading = false);
      }
    }
  }

  void _listenUser() {
    final user = currentUser;
    if (user == null) {
      if (mounted) setState(() => loading = false);
      return;
    }

    _userListener = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen(
          (doc) {
            if (mounted && loading) {
              setState(() => loading = false);
            }
            if (!doc.exists) return;

            final data = doc.data();
            if (mounted) {
              setState(() {
                if (data?['name'] != null &&
                    data!['name'].toString().isNotEmpty) {
                  _nameController.text = data['name'];
                }
                final code = data?['uniqueCode'];
                if (code != null && code.toString().isNotEmpty) {
                  _codeController.text = code.toString();
                }
                photoUrl = data?['photoUrl'];
              });
            }
          },
          onError: (e) {
            debugPrint("User listener error: $e");
            if (mounted) setState(() => loading = false);
          },
        );
  }

  bool _canPerformAction() {
    final now = DateTime.now();
    if (lastActionTime == null) {
      lastActionTime = now;
      return true;
    }
    final diff = now.difference(lastActionTime!).inSeconds;
    if (diff < 5) {
      _showMsg("Please wait before trying again");
      return false;
    }
    lastActionTime = now;
    return true;
  }

  bool _isValidCode(String code) {
    if (!CodeService.isValidFormat(code)) {
      _showMsg("Code must be 6-8 characters (letters and numbers)");
      return false;
    }
    return true;
  }

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
        _showMsg("Authentication not supported");
        return;
      }
      bool authenticated = await auth.authenticate(
        localizedReason: "Authenticate to view device code",
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      if (authenticated) {
        setState(() => showCode = true);
        hideTimer?.cancel();
        hideTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => showCode = false);
        });
      }
    } catch (_) {
      _showMsg("Authentication error");
    }
  }

  Future<void> _changeUniqueCode() async {
    if (!_canPerformAction()) return;
    final user = currentUser;
    if (user == null) {
      _showMsg("User not logged in");
      return;
    }

    if (deviceId == null || deviceId!.isEmpty) {
      deviceId = await DeviceService.registerDevice().timeout(
        const Duration(seconds: 4),
        onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
      );
    }

    final controller = TextEditingController();
    if (!mounted) return;
    final newCode = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Enter New Code"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "Example: ABC123"),
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
            child: const Text("Update"),
          ),
        ],
      ),
    );

    if (newCode == null || newCode.isEmpty) return;
    if (!_isValidCode(newCode)) {
      _showMsg("Code must be 6 to 8 alphanumeric characters");
      return;
    }

    final res = await CodeService.createCustomCode(newCode, deviceId!);
    if (res.success && res.code != null) {
      if (mounted) {
        setState(() {
          _codeController.text = res.code!;
        });
      }
    }
    _showMsg(res.message);
  }

  Future<void> _logout() async {
    if (!_canPerformAction()) return;
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => AuthGate(
            onThemeChanged: (mode) {
              if (widget.onThemeChanged != null) {
                widget.onThemeChanged!(mode);
              }
            },
          ),
        ),
        (route) => false,
      );
    }
  }

  Future<void> _confirmDelete() async {
    if (!_canPerformAction()) return;
    final user = currentUser;
    if (user == null) {
      _showMsg("Delete account failed: No authenticated user.");
      return;
    }

    bool isGoogleUser = user.providerData.any(
      (p) => p.providerId == 'google.com',
    );
    final passwordController = TextEditingController();
    bool obscurePassword = true;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text(
            "Security Check",
            style: TextStyle(color: Colors.red),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("This will permanently delete your account."),
              if (!isGoogleUser)
                Padding(
                  padding: const EdgeInsets.only(top: 15),
                  child: TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: "Password to confirm",
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () => setDialogState(
                          () => obscurePassword = !obscurePassword,
                        ),
                      ),
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 15),
                  child: Text(
                    "Linked with Google: No password required.",
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                "Delete Permanently",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) {
      passwordController.dispose();
      return;
    }

    final password = passwordController.text.trim();
    passwordController.dispose();

    try {
      setState(() => loading = true);

      debugPrint("Delete Account Started");
      debugPrint("Current UID: ${user.uid}");

      if (!isGoogleUser && password.isNotEmpty) {
        await _reauthenticateForDeletion(user, password);
      }

      final currentCode = await _resolveDeviceCodeForDeletion(user);

      await _stopForegroundServices(currentCode, allowStatusWrite: true);
      await _deleteFirestoreAccountData(uid: user.uid, deviceCode: currentCode);
      await _deleteStorageFiles(uid: user.uid, deviceCode: currentCode);
      await _deleteFirebaseAuthUserWithRetry(user, password);
      await _clearLocalAccountData();
      await _stopForegroundServices(currentCode, allowStatusWrite: false);

      if (mounted) {
        setState(() => loading = false);
        _showMsg("Account deleted permanently.");
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/login', (route) => false);
      }
    } catch (e, stackTrace) {
      debugPrint("Delete Account Failed: ${_errorDetails(e)}");
      debugPrint("Exception: $e");
      debugPrint("Stack Trace: $stackTrace");
      if (mounted) setState(() => loading = false);
      _showMsg("Error deleting account: ${_errorDetails(e)}");
    }
  }

  Future<String?> _resolveDeviceCodeForDeletion(User user) async {
    final controllerCode = _codeController.text.trim().toUpperCase();
    if (controllerCode.isNotEmpty) {
      debugPrint("Resolved Device Code from UI: $controllerCode");
      return controllerCode;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedCode =
          prefs.getString('uniqueCode') ??
          prefs.getString('cached_code_${user.uid}');

      if (cachedCode != null && cachedCode.trim().isNotEmpty) {
        final code = cachedCode.trim().toUpperCase();
        debugPrint("Resolved Device Code from SharedPreferences: $code");
        return code;
      }

      debugPrint("Reading device code from users/${user.uid}");
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = userDoc.data();
      final rawCode = data?['uniqueCode'] ?? data?['deviceCode'];

      if (rawCode != null && rawCode.toString().trim().isNotEmpty) {
        final code = rawCode.toString().trim().toUpperCase();
        debugPrint("Resolved Device Code from Firestore: $code");
        return code;
      }

      debugPrint("No device code found for account deletion");
      return null;
    } catch (e, stackTrace) {
      debugPrint("Resolve Device Code Failed: ${_errorDetails(e)}");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  Future<void> _stopForegroundServices(
    String? deviceCode, {
    required bool allowStatusWrite,
  }) async {
    debugPrint("Stopping Foreground Services");

    try {
      LocationService().stopTracking();

      if (!kIsWeb) {
        final stopped = allowStatusWrite && deviceCode != null
            ? await BackgroundTracking.stop(deviceCode)
            : await BackgroundTracking.stopLocalService();
        debugPrint("Foreground Service Stop Result: $stopped");
      }

      debugPrint("Success: Foreground Services Stopped");
    } catch (e, stackTrace) {
      debugPrint("Stop Foreground Services Failed: ${_errorDetails(e)}");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  Future<void> _deleteFirestoreAccountData({
    required String uid,
    required String? deviceCode,
  }) async {
    final db = FirebaseFirestore.instance;

    try {
      debugPrint("Deleting Firestore User: users/$uid");
      await db.collection('users').doc(uid).delete();
      debugPrint("Success: Deleted Firestore User");

      await _deleteUserDevices(uid);

      if (deviceCode == null || deviceCode.isEmpty) {
        debugPrint("Skipping device-code Firestore cleanup: no code found");
        return;
      }

      debugPrint("Deleting Device Code: device_codes/$deviceCode");
      await db.collection('device_codes').doc(deviceCode).delete();
      debugPrint("Success: Deleted Device Code");

      await _deleteTopLevelDeviceDocument(
        collection: 'device_images',
        docId: deviceCode,
        subcollections: const ['photos'],
      );
      await _deleteTopLevelDeviceDocument(
        collection: 'device_audio',
        docId: deviceCode,
        subcollections: const ['records'],
      );
      await _deleteTopLevelDeviceDocument(
        collection: 'device_scans',
        docId: deviceCode,
        subcollections: const ['scans', 'wifi', 'bluetooth'],
      );
      await _deleteTopLevelDeviceDocument(
        collection: 'device_commands',
        docId: deviceCode,
        subcollections: const [],
      );
      await _deleteTopLevelDeviceDocument(
        collection: 'device_timeline',
        docId: deviceCode,
        subcollections: const ['events'],
      );
    } catch (e, stackTrace) {
      debugPrint("Firestore Delete Failed: ${_errorDetails(e)}");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  Future<void> _deleteUserDevices(String uid) async {
    final devicesRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('devices');

    debugPrint("Deleting user device subcollections: users/$uid/devices");

    final devices = await devicesRef.get();
    for (final deviceDoc in devices.docs) {
      await _deleteCollection(
        deviceDoc.reference.collection('locations'),
        "users/$uid/devices/${deviceDoc.id}/locations",
      );
      await deviceDoc.reference.delete();
      debugPrint("Success: Deleted user device ${deviceDoc.id}");
    }
  }

  Future<void> _deleteTopLevelDeviceDocument({
    required String collection,
    required String docId,
    required List<String> subcollections,
  }) async {
    final docRef = FirebaseFirestore.instance.collection(collection).doc(docId);

    debugPrint("Deleting $collection/$docId");

    for (final subcollection in subcollections) {
      await _deleteCollection(
        docRef.collection(subcollection),
        "$collection/$docId/$subcollection",
      );
    }

    await docRef.delete();
    debugPrint("Success: Deleted $collection/$docId");
  }

  Future<void> _deleteCollection(
    CollectionReference<Map<String, dynamic>> collection,
    String label,
  ) async {
    const batchSize = 300;

    while (true) {
      final snapshot = await collection.limit(batchSize).get();
      if (snapshot.docs.isEmpty) {
        debugPrint("Success: No remaining documents in $label");
        return;
      }

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snapshot.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      debugPrint(
        "Success: Deleted ${snapshot.docs.length} documents from $label",
      );

      if (snapshot.docs.length < batchSize) return;
    }
  }

  Future<void> _deleteStorageFiles({
    required String uid,
    required String? deviceCode,
  }) async {
    try {
      debugPrint("Deleting Storage: profile_photos/$uid.jpg");
      await _deleteStorageObject("profile_photos/$uid.jpg");

      if (deviceCode != null && deviceCode.isNotEmpty) {
        debugPrint("Deleting Storage Folder: lost_images/$deviceCode");
        await _deleteStorageFolder(
          FirebaseStorage.instance.ref().child("lost_images/$deviceCode"),
        );

        debugPrint("Deleting Storage Folder: lost_audio/$deviceCode");
        await _deleteStorageFolder(
          FirebaseStorage.instance.ref().child("lost_audio/$deviceCode"),
        );
      }

      debugPrint("Success: Deleted Storage");
    } catch (e, stackTrace) {
      debugPrint("Deleting Storage Failed: ${_errorDetails(e)}");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  Future<void> _deleteStorageObject(String path) async {
    try {
      await FirebaseStorage.instance.ref().child(path).delete();
      debugPrint("Success: Deleted Storage Object $path");
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') {
        debugPrint("Storage Object Already Missing: $path");
        return;
      }
      rethrow;
    }
  }

  Future<void> _deleteStorageFolder(Reference ref) async {
    final result = await ref.listAll();

    for (final childRef in result.prefixes) {
      await _deleteStorageFolder(childRef);
    }

    for (final itemRef in result.items) {
      await itemRef.delete();
      debugPrint("Success: Deleted Storage Object ${itemRef.fullPath}");
    }
  }

  Future<void> _deleteFirebaseAuthUserWithRetry(
    User user,
    String initialPassword,
  ) async {
    try {
      debugPrint("Deleting Auth User: ${user.uid}");
      await user.delete();
      debugPrint("Success: Deleted Auth User");
    } on FirebaseAuthException catch (e, stackTrace) {
      debugPrint("Deleting Auth User Failed: ${_errorDetails(e)}");
      debugPrint("Reason: ${e.code}");
      debugPrint("Stack Trace: $stackTrace");

      if (e.code != 'requires-recent-login') {
        rethrow;
      }

      if (mounted) {
        await _showReauthRequiredDialog();
      }

      await _reauthenticateForDeletion(user, initialPassword);

      final refreshedUser = FirebaseAuth.instance.currentUser;
      if (refreshedUser == null) {
        throw FirebaseAuthException(
          code: 'no-current-user',
          message: 'Re-authentication completed but no current user exists.',
        );
      }

      debugPrint("Retrying Auth User Delete: ${refreshedUser.uid}");
      await refreshedUser.delete();
      debugPrint("Success: Deleted Auth User After Re-authentication");
    }
  }

  Future<void> _reauthenticateForDeletion(
    User user,
    String initialPassword,
  ) async {
    try {
      debugPrint("Re-authentication Started");
      final providerIds = user.providerData.map((p) => p.providerId).toSet();

      if (providerIds.contains('password') &&
          user.email != null &&
          user.email!.isNotEmpty) {
        final password = initialPassword.isNotEmpty
            ? initialPassword
            : await _promptPasswordForDeletion();

        if (password == null || password.isEmpty) {
          throw FirebaseAuthException(
            code: 'requires-recent-login',
            message: 'Please sign in again to confirm account deletion.',
          );
        }

        final credential = EmailAuthProvider.credential(
          email: user.email!,
          password: password,
        );
        await user.reauthenticateWithCredential(credential);
        debugPrint("Success: Re-authenticated with password");
        return;
      }

      if (providerIds.contains('google.com')) {
        if (kIsWeb) {
          await user.reauthenticateWithProvider(GoogleAuthProvider());
        } else {
          final googleUser = await GoogleSignIn(scopes: ['email']).signIn();
          if (googleUser == null) {
            throw FirebaseAuthException(
              code: 'google-reauth-cancelled',
              message: 'Google sign-in was cancelled.',
            );
          }

          final googleAuth = await googleUser.authentication;
          final credential = GoogleAuthProvider.credential(
            accessToken: googleAuth.accessToken,
            idToken: googleAuth.idToken,
          );
          await user.reauthenticateWithCredential(credential);
        }

        debugPrint("Success: Re-authenticated with Google");
        return;
      }

      throw FirebaseAuthException(
        code: 'unsupported-provider',
        message: 'Please sign in again to confirm account deletion.',
      );
    } catch (e, stackTrace) {
      debugPrint("Re-authentication Failed: ${_errorDetails(e)}");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  Future<void> _showReauthRequiredDialog() async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Sign in again"),
        content: const Text(
          "Please sign in again to confirm account deletion.",
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Continue"),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptPasswordForDeletion() async {
    if (!mounted) return null;

    final controller = TextEditingController();
    bool obscurePassword = true;

    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Sign in again"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Please sign in again to confirm account deletion."),
              const SizedBox(height: 15),
              TextField(
                controller: controller,
                obscureText: obscurePassword,
                decoration: InputDecoration(
                  labelText: "Password",
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscurePassword ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setDialogState(
                      () => obscurePassword = !obscurePassword,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text("Continue"),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    return password;
  }

  Future<void> _clearLocalAccountData() async {
    try {
      debugPrint("Clearing SharedPreferences");
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      debugPrint("Success: SharedPreferences Cleared");

      debugPrint("Clearing Offline Location Cache");
      await OfflineLocationService.clearLocations();
      debugPrint("Success: Offline Location Cache Cleared");

      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      debugPrint("Success: Flutter Image Cache Cleared");

      if (!kIsWeb) {
        final tempDir = await getTemporaryDirectory();
        await _deleteDirectoryContents(tempDir);
        debugPrint("Success: Temporary Files Cleared");
      }
    } catch (e, stackTrace) {
      debugPrint("Clear Local Data Failed: ${_errorDetails(e)}");
      debugPrint("Stack Trace: $stackTrace");
      rethrow;
    }
  }

  Future<void> _deleteDirectoryContents(Directory directory) async {
    if (!await directory.exists()) return;

    await for (final entity in directory.list(followLinks: false)) {
      await entity.delete(recursive: true);
    }
  }

  String _errorDetails(Object error) {
    if (error is FirebaseException) {
      return "${error.plugin}/${error.code}: ${error.message ?? error.toString()}";
    }
    return error.toString().replaceAll("Exception:", "").trim();
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xff121212)
          : const Color(0xffF4F6FA),

      // 🔥 THEME TOGGLE BUTTON FIX
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (widget.onThemeChanged != null) {
            widget.onThemeChanged!(isDark ? ThemeMode.light : ThemeMode.dark);
          } else {
            _showMsg("Theme change not linked properly in parent widget");
          }
        },
        backgroundColor: Colors.blue,
        child: Icon(
          isDark ? Icons.light_mode : Icons.dark_mode,
          color: Colors.white,
        ),
      ),

      body: SingleChildScrollView(
        child: Column(
          children: [
            // HEADER SECTION
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 30),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xff3A6FE2), Color(0xff2453C5)],
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(30),
                  bottomRight: Radius.circular(30),
                ),
              ),
              child: Column(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 50,
                        backgroundColor: Colors.white24,
                        backgroundImage: photoUrl != null
                            ? NetworkImage(photoUrl!)
                            : (currentUser?.photoURL != null
                                  ? NetworkImage(currentUser!.photoURL!)
                                  : null),
                        child:
                            (photoUrl == null && currentUser?.photoURL == null)
                            ? const Icon(
                                Icons.person,
                                size: 50,
                                color: Colors.white,
                              )
                            : null,
                      ),
                      if (uploadingPhoto)
                        const Positioned.fill(
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                        ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: _pickImage,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.camera_alt,
                              size: 18,
                              color: Colors.blue,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nameController,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: "Enter Name",
                      hintStyle: TextStyle(color: Colors.white54),
                    ),
                    onSubmitted: (val) async {
                      if (val.trim().isEmpty) return;
                      await FirebaseFirestore.instance
                          .collection('users')
                          .doc(currentUser!.uid)
                          .update({'name': val.trim()});
                    },
                  ),
                  const Text(
                    "Active Member",
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Use ConstrainedBox for Web view consistency
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  children: [
                    _sectionCard(
                      isDark: isDark,
                      title: "Account Information",
                      children: [
                        _infoTile(
                          isDark,
                          Icons.email,
                          "Email",
                          currentUser?.email ?? "",
                        ),
                        _codeTile(isDark),
                      ],
                    ),
                    const SizedBox(height: 15),
                    _sectionCard(
                      isDark: isDark,
                      title: "Quick Actions",
                      children: [
                        _actionTile(
                          isDark,
                          Icons.vpn_key,
                          "Change Device Code",
                          _changeUniqueCode,
                        ),
                        _actionTile(
                          isDark,
                          Icons.lock_reset,
                          "Reset Password",
                          () async {
                            await FirebaseAuth.instance.sendPasswordResetEmail(
                              email: currentUser!.email!,
                            );
                            _showMsg("Password reset email sent!");
                          },
                        ),
                        _actionTile(isDark, Icons.logout, "Logout", _logout),
                      ],
                    ),
                    const SizedBox(height: 15),
                    _sectionCard(
                      isDark: isDark,
                      title: "Security & Danger Zone",
                      children: [
                        _actionTile(
                          isDark,
                          Icons.delete_forever,
                          "Delete Account",
                          _confirmDelete,
                          color: Colors.red,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 80), // Space for FAB
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({
    required bool isDark,
    required String title,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xff1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: isDark ? Colors.blue : Colors.grey,
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _actionTile(
    bool isDark,
    IconData icon,
    String text,
    VoidCallback onTap, {
    Color? color,
  }) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (color ?? Colors.blue).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color ?? Colors.blue, size: 20),
        ),
        title: Text(
          text,
          style: TextStyle(
            color: color ?? (isDark ? Colors.white : Colors.black87),
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: const Icon(
          Icons.arrow_forward_ios,
          size: 14,
          color: Colors.grey,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _codeTile(bool isDark) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.qr_code, color: Colors.blue, size: 20),
        ),
        title: Text(
          "Device Tracking Code",
          style: TextStyle(
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        subtitle: Text(
          showCode ? _codeController.text : "••••••",
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
        trailing: IconButton(
          icon: Icon(
            showCode ? Icons.visibility_off : Icons.visibility,
            color: Colors.grey,
          ),
          onPressed: _authenticateAndShowCode,
        ),
      ),
    );
  }

  Widget _infoTile(bool isDark, IconData icon, String title, String value) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.blue, size: 20),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        subtitle: Text(
          value,
          style: TextStyle(color: isDark ? Colors.white70 : Colors.black54),
        ),
      ),
    );
  }

  Future<void> _pickImage() async {
    final user = currentUser;
    if (user == null) return;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 70,
      );
      if (picked == null) return;
      setState(() => uploadingPhoto = true);
      final storageRef = FirebaseStorage.instance.ref().child(
        "profile_photos/${user.uid}.jpg",
      );
      if (kIsWeb) {
        final bytes = await picked.readAsBytes();
        await storageRef.putData(bytes);
      } else {
        await storageRef.putFile(File(picked.path));
      }
      final downloadUrl = await storageRef.getDownloadURL();
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {'photoUrl': downloadUrl},
      );
      setState(() {
        photoUrl = downloadUrl;
        uploadingPhoto = false;
      });
      _showMsg("Profile photo updated");
    } catch (e) {
      setState(() => uploadingPhoto = false);
      _showMsg("Photo upload failed");
    }
  }
}
