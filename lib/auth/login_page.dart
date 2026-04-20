import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'; // 🔥 Required for kIsWeb
import '../services/auth_service.dart';

// 🔥 REQUIRED SERVICES
import '../services/background_service.dart';
import '../services/location_permission.dart';
import '../services/device_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool isLogin = true;
  bool obscurePassword = true;
  bool isLoading = false; 
  String error = "";

  // Password Validation States
  bool hasUpper = false;
  bool hasLower = false;
  bool hasNumber = false;
  bool hasSpecial = false;
  bool hasMinLength = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _validatePassword(String value) {
    setState(() {
      hasUpper = value.contains(RegExp(r'[A-Z]'));
      hasLower = value.contains(RegExp(r'[a-z]'));
      hasNumber = value.contains(RegExp(r'[0-9]'));
      hasSpecial = value.contains(RegExp(r'[!@#\$&*~]'));
      hasMinLength = value.length >= 6;
    });
  }

  // ================= SUBMIT LOGIC (MOBILE & WEB SYNC) =================

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => error = "Please enter email and password");
      return;
    }

    if (!isLogin && !(hasUpper && hasLower && hasNumber && hasSpecial && hasMinLength)) {
      setState(() => error = "Please meet all password requirements");
      return;
    }

    try {
      setState(() {
        error = "";
        isLoading = true;
      });

      UserCredential userCredential;

      if (isLogin) {
        // ================= LOGIN =================
        userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );

        // 🔥 FIX: GET FRESH USER AFTER RELOAD
        await FirebaseAuth.instance.currentUser?.reload();
        final freshUser = FirebaseAuth.instance.currentUser;

        if (freshUser != null && !freshUser.emailVerified) {
          await FirebaseAuth.instance.signOut();

          setState(() {
            error = "Please verify your email before login";
          });
          return;
        }

      } else {
        // ================= SIGNUP =================

        // 🔥 FIX: PREVENT DUPLICATE BEFORE CREATE
        final methods = await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
        if (methods.isNotEmpty) {
          setState(() => error = "Account already exists");
          return;
        }

        userCredential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );

        // 🔥 SEND VERIFICATION EMAIL
        await userCredential.user!.sendEmailVerification();

        setState(() {
          error = "Verification email sent. Check your inbox.";
        });

        return;
      }

      // ================= POST AUTH =================
      final user = FirebaseAuth.instance.currentUser;

      if (user != null) {
        final deviceId = await DeviceService.registerDevice();

        if (!kIsWeb) {
          await LocationPermissionHelper.request();

          if (deviceId != null) {
            await BackgroundTracking.start(deviceId);
          }
        }
      }

    } on FirebaseAuthException catch (e) {
      setState(() {
        if (e.code == 'user-not-found') error = "No user found for that email.";
        else if (e.code == 'wrong-password') error = "Wrong password provided.";
        else if (e.code == 'invalid-email') error = "Invalid email format.";
        else if (e.code == 'email-already-in-use') error = "Account already exists.";
        else error = e.message ?? "Authentication error";
      });
    } catch (e) {
      setState(() => error = "An unexpected error occurred.");
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ================= GOOGLE LOGIN old=================

  Future<void> _googleLogin() async {
    try {
      setState(() {
        error = "";
        isLoading = true;
      });

      final user = await AuthService().signInWithGoogle();

      if (user != null) {
        final deviceId = await DeviceService.registerDevice();
        if (!kIsWeb) {
          await LocationPermissionHelper.request();
          if (deviceId != null) {
            await BackgroundTracking.start(deviceId);
          }
        }
      }
    } catch (e) {
      setState(() => error = "Google Sign-In failed.");
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => error = "Enter email to reset password");
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Password reset email sent!")),
      );
    } catch (e) {
      setState(() => error = "Failed to send reset email.");
    }
  }

  Widget _rule(String text, bool valid) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(valid ? Icons.check_circle : Icons.circle, size: 14, color: valid ? Colors.green : Colors.grey),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(color: valid ? Colors.green : Colors.black87, fontSize: 12), // 🔥 Black text
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // 🔥 Force white background
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400), // 🔥 Keeps UI clean on Web
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // APP LOGO
                Image.asset(
                  'assets/icon/fincell_icon.png',
                  height: 100,
                  errorBuilder: (context, error, stackTrace) {
                    return const Icon(Icons.phone_android, size: 80, color: Colors.blue);
                  },
                ),
                const SizedBox(height: 10),
                const Text(
                  "FinCell",
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.black87), // 🔥 Black
                ),
                const Text(
                  "Lost Device Tracker",
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 40),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    isLogin ? "Login" : "Create Account",
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black), // 🔥 Black
                  ),
                ),
                const SizedBox(height: 20),

                // EMAIL FIELD
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Colors.black), // 🔥 Input text black
                  decoration: InputDecoration(
                    labelText: "Email address",
                    labelStyle: const TextStyle(color: Colors.black54),
                    prefixIcon: const Icon(Icons.email_outlined, color: Colors.blue),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.black26),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // PASSWORD FIELD
                TextField(
                  controller: _passwordController,
                  obscureText: obscurePassword,
                  onChanged: _validatePassword,
                  style: const TextStyle(color: Colors.black), // 🔥 Input text black
                  decoration: InputDecoration(
                    labelText: isLogin ? "Password" : "Create password",
                    labelStyle: const TextStyle(color: Colors.black54),
                    prefixIcon: const Icon(Icons.lock_outline, color: Colors.blue),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.black26),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(obscurePassword ? Icons.visibility : Icons.visibility_off, color: Colors.grey),
                      onPressed: () => setState(() => obscurePassword = !obscurePassword),
                    ),
                  ),
                ),

                // PASSWORD RULES
                if (!isLogin) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Requirements:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black)),
                        const SizedBox(height: 6),
                        _rule("At least 6 characters", hasMinLength),
                        _rule("One uppercase letter", hasUpper),
                        _rule("One lowercase letter", hasLower),
                        _rule("One number", hasNumber),
                        _rule("One special character", hasSpecial),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(error, style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w500)),
                  ),

                // SUBMIT BUTTON
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      backgroundColor: const Color(0xff1E88E5),
                      foregroundColor: Colors.white,
                      elevation: 0,
                    ),
                    onPressed: isLoading ? null : _submit,
                    child: isLoading 
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text(isLogin ? "Login" : "Register", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),

                const SizedBox(height: 15),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(isLogin ? "New user?" : "Already have an account?", style: const TextStyle(color: Colors.black54)),
                    TextButton(
                      onPressed: () => setState(() { isLogin = !isLogin; error = ""; }),
                      child: Text(isLogin ? "Create account" : "Login", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xff1E88E5))),
                    ),
                  ],
                ),

                if (isLogin)
                  TextButton(onPressed: _forgotPassword, child: const Text("Forgot Password?", style: TextStyle(color: Colors.black45))),

                const SizedBox(height: 20),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text("OR", style: TextStyle(color: Colors.grey))),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 20),

                // GOOGLE LOGIN
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      side: const BorderSide(color: Colors.black12),
                    ),
                    icon: const Icon(Icons.login_rounded, size: 20, color: Colors.blueAccent),
                    label: const Text("Continue with Google", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w500)),
                    onPressed: isLoading ? null : _googleLogin,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}