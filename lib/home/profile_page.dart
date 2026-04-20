import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show File;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'dart:async';

import '../services/device_service.dart';

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
    deviceId = await DeviceService.registerDevice();
    _listenUser();
  }

  void _listenUser() {
    final user = currentUser;
    if (user == null) return;

    _userListener = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((doc) {
      if (!doc.exists) return;
      final data = doc.data();
      if (mounted) {
        setState(() {
          _nameController.text = data?['name'] ?? "";
          final code = data?['uniqueCode'];
          _codeController.text = (code != null && code.toString().isNotEmpty) ? code : "---";
          photoUrl = data?['photoUrl'];
          loading = false;
        });
      }
    });
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
    final regex = RegExp(r'^[A-Z0-9]{6,8}$');
    if (!regex.hasMatch(code)) {
      _showMsg("Code must be 6-8 characters (A-Z, 0-9)");
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
      bool canAuthenticate = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (!canAuthenticate) {
        _showMsg("Authentication not supported");
        return;
      }
      bool authenticated = await auth.authenticate(
        localizedReason: "Authenticate to view device code",
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
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
    if (user == null || deviceId == null) {
      _showMsg("Device not ready");
      return;
    }
    final controller = TextEditingController();
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim().toUpperCase()),
            child: const Text("Update"),
          )
        ],
      ),
    );

    if (newCode == null || newCode.isEmpty) return;
    if (!_isValidCode(newCode)) return;

    final oldCode = _codeController.text;

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final newRef = FirebaseFirestore.instance.collection('device_codes').doc(newCode);
        final snap = await tx.get(newRef);
        if (snap.exists) throw Exception("Code taken");
        if (oldCode.isNotEmpty && oldCode != "---") {
          tx.delete(FirebaseFirestore.instance.collection('device_codes').doc(oldCode));
        }
        tx.set(newRef, {
          'ownerUid': user.uid,
          'deviceId': deviceId,
          'isLost': false,
          'lastLocation': null,
          'createdAt': FieldValue.serverTimestamp(),
        });
        tx.update(FirebaseFirestore.instance.collection('users').doc(user.uid), {'uniqueCode': newCode});
      });
      _showMsg("Code updated successfully");
    } catch (e) {
      _showMsg("Code already exists or error occurred");
    }
  }

  Future<void> _logout() async {
    if (!_canPerformAction()) return;
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _confirmDelete() async {
    if (!_canPerformAction()) return;
    final user = currentUser;
    if (user == null) return;

    bool isGoogleUser = user.providerData.any((p) => p.providerId == 'google.com');
    final passwordController = TextEditingController();
    bool obscurePassword = true;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Security Check", style: TextStyle(color: Colors.red)),
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
                        icon: Icon(obscurePassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                      ),
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 15),
                  child: Text("Linked with Google: No password required.", style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Delete Permanently", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    try {
      setState(() => loading = true);
      if (!isGoogleUser) {
        final cred = EmailAuthProvider.credential(email: user.email!, password: passwordController.text.trim());
        await user.reauthenticateWithCredential(cred);
      }
      await FirebaseFirestore.instance.collection('users').doc(user.uid).delete();
      await user.delete();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) setState(() => loading = false);
      _showMsg("Error during deletion.");
    }
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
      backgroundColor: isDark ? const Color(0xff121212) : const Color(0xffF4F6FA),
      
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
        child: Icon(isDark ? Icons.light_mode : Icons.dark_mode, color: Colors.white),
      ),

      body: SingleChildScrollView(
        child: Column(
          children: [
            // HEADER SECTION
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 30),
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xff3A6FE2), Color(0xff2453C5)]),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(30), bottomRight: Radius.circular(30)),
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
                            : (currentUser?.photoURL != null ? NetworkImage(currentUser!.photoURL!) : null),
                        child: (photoUrl == null && currentUser?.photoURL == null)
                            ? const Icon(Icons.person, size: 50, color: Colors.white)
                            : null,
                      ),
                      if (uploadingPhoto)
                        const Positioned.fill(child: Center(child: CircularProgressIndicator(color: Colors.white))),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: _pickImage,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            child: const Icon(Icons.camera_alt, size: 18, color: Colors.blue),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nameController,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(border: InputBorder.none, hintText: "Enter Name", hintStyle: TextStyle(color: Colors.white54)),
                    onSubmitted: (val) async {
                      if (val.trim().isEmpty) return;
                      await FirebaseFirestore.instance.collection('users').doc(currentUser!.uid).update({'name': val.trim()});
                    },
                  ),
                  const Text("Active Member", style: TextStyle(color: Colors.white70)),
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
                        _infoTile(isDark, Icons.email, "Email", currentUser?.email ?? ""),
                        _codeTile(isDark),
                      ],
                    ),
                    const SizedBox(height: 15),
                    _sectionCard(
                      isDark: isDark,
                      title: "Quick Actions",
                      children: [
                        _actionTile(isDark, Icons.vpn_key, "Change Device Code", _changeUniqueCode),
                        _actionTile(isDark, Icons.lock_reset, "Reset Password", () async {
                          await FirebaseAuth.instance.sendPasswordResetEmail(email: currentUser!.email!);
                          _showMsg("Password reset email sent!");
                        }),
                        _actionTile(isDark, Icons.logout, "Logout", _logout),
                      ],
                    ),
                    const SizedBox(height: 15),
                    _sectionCard(
                      isDark: isDark,
                      title: "Security & Danger Zone",
                      children: [
                        _actionTile(isDark, Icons.delete_forever, "Delete Account", _confirmDelete, color: Colors.red),
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

  Widget _sectionCard({required bool isDark, required String title, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xff1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? Colors.blue : Colors.grey)),
            const SizedBox(height: 10),
            ...children
          ],
        ),
      ),
    );
  }

  Widget _actionTile(bool isDark, IconData icon, String text, VoidCallback onTap, {Color? color}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: (color ?? Colors.blue).withOpacity(0.1), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: color ?? Colors.blue, size: 20)),
      title: Text(text, style: TextStyle(color: color ?? (isDark ? Colors.white : Colors.black87), fontWeight: FontWeight.w500)),
      trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
      onTap: onTap,
    );
  }

  Widget _codeTile(bool isDark) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.qr_code, color: Colors.blue, size: 20)),
      title: Text("Device Tracking Code", style: TextStyle(fontWeight: FontWeight.w500, color: isDark ? Colors.white : Colors.black87)),
      subtitle: Text(showCode ? _codeController.text : "••••••", style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.black54)),
      trailing: IconButton(icon: Icon(showCode ? Icons.visibility_off : Icons.visibility, color: Colors.grey), onPressed: _authenticateAndShowCode),
    );
  }

  Widget _infoTile(bool isDark, IconData icon, String title, String value) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: Colors.blue, size: 20)),
      title: Text(title, style: TextStyle(fontWeight: FontWeight.w500, color: isDark ? Colors.white : Colors.black87)),
      subtitle: Text(value, style: TextStyle(color: isDark ? Colors.white70 : Colors.black54)),
    );
  }

  Future<void> _pickImage() async {
    final user = currentUser;
    if (user == null) return;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (picked == null) return;
      setState(() => uploadingPhoto = true);
      final storageRef = FirebaseStorage.instance.ref().child("profile_photos/${user.uid}.jpg");
      if (kIsWeb) {
        final bytes = await picked.readAsBytes();
        await storageRef.putData(bytes);
      } else {
        await storageRef.putFile(File(picked.path));
      }
      final downloadUrl = await storageRef.getDownloadURL();
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({'photoUrl': downloadUrl});
      setState(() { photoUrl = downloadUrl; uploadingPhoto = false; });
      _showMsg("Profile photo updated");
    } catch (e) {
      setState(() => uploadingPhoto = false);
      _showMsg("Photo upload failed");
    }
  }
}