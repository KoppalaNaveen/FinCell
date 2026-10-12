import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'; // 🔥 Required for kIsWeb
import '../services/auth_service.dart';

// 🔥 REQUIRED SERVICES
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

    if (!isLogin &&
        !(hasUpper && hasLower && hasNumber && hasSpecial && hasMinLength)) {
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
        userCredential = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(email: email, password: password);

        // 🔥 Create user document in Firestore immediately on signup
        final newUser = userCredential.user;
        if (newUser != null) {
          try {
            await AuthService.ensureUserDocument(newUser);
          } catch (e) {
            debugPrint("Signup user document creation error: $e");
          }
        }

        // 🔥 SEND VERIFICATION EMAIL
        await userCredential.user!.sendEmailVerification();

        // Sign out so the user must verify email before accessing the app
        await FirebaseAuth.instance.signOut();

        if (mounted) {
          setState(() {
            error = "Verification email sent. Check your inbox.";
          });
        }

        return;
      }

      // ================= POST AUTH =================
      final user = FirebaseAuth.instance.currentUser;

      if (user != null) {
        // 🔥 Ensure user document exists in Firestore (covers email login path)
        try {
          await AuthService.ensureUserDocument(user);
        } catch (e) {
          debugPrint("Login ensureUserDocument error: $e");
        }

        try {
          await DeviceService.registerDevice().timeout(
            const Duration(seconds: 4),
            onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
          );
        } catch (e) {
          debugPrint("Login device registration error: $e");
        }

        if (!kIsWeb) {
          try {
            await LocationPermissionHelper.request().timeout(
              const Duration(seconds: 4),
            );
          } catch (e) {
            debugPrint("Login permission request error: $e");
          }
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          if (e.code == 'user-not-found') {
            error = "No user found for that email.";
          } else if (e.code == 'wrong-password') {
            error = "Wrong password provided.";
          } else if (e.code == 'invalid-email') {
            error = "Invalid email format.";
          } else if (e.code == 'email-already-in-use') {
            error = "Account already exists.";
          } else {
            error = e.message ?? "Authentication error";
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = "An unexpected error occurred.");
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ================= GOOGLE LOGIN =================

  Future<void> _googleLogin() async {
    try {
      setState(() {
        error = "";
        isLoading = true;
      });

      final user = await AuthService().signInWithGoogle();

      if (user != null) {
        try {
          await DeviceService.registerDevice().timeout(
            const Duration(seconds: 4),
            onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
          );
        } catch (e) {
          debugPrint("Google login device registration error: $e");
        }

        if (!kIsWeb) {
          try {
            await LocationPermissionHelper.request().timeout(
              const Duration(seconds: 4),
            );
          } catch (e) {
            debugPrint("Google login permission request error: $e");
          }
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => error = e.message ?? "Google Sign-In failed.");
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = "Google Sign-In failed: $e");
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ================= GUEST LOGIN =================

  Future<void> _guestLogin() async {
    try {
      setState(() {
        error = "";
        isLoading = true;
      });

      final user = await AuthService().signInAnonymously();

      if (user != null) {
        try {
          await DeviceService.registerDevice().timeout(
            const Duration(seconds: 4),
            onTimeout: () => "device_${DateTime.now().millisecondsSinceEpoch}",
          );
        } catch (e) {
          debugPrint("Guest login device registration error: $e");
        }

        if (!kIsWeb) {
          try {
            await LocationPermissionHelper.request().timeout(
              const Duration(seconds: 4),
            );
          } catch (e) {
            debugPrint("Guest login permission request error: $e");
          }
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          if (e.code == 'admin-restricted-operation') {
            error = "Guest sign-in is currently unavailable. Please use Google Sign-In or create an account.";
          } else {
            error = e.message ?? "Guest Sign-In failed.";
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = "Guest Sign-In failed: $e");
      }
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
      setState(() => error = "Password reset failed");
    }
  }

  Widget _rule(String text, bool valid) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            valid ? Icons.check_circle : Icons.circle_outlined,
            size: 14,
            color: valid ? Colors.green : Colors.black45, // 🔥 Black/Grey
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: valid ? Colors.green : Colors.black87,
              fontSize: 12,
            ), // 🔥 Black text
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
            constraints: const BoxConstraints(
              maxWidth: 400,
            ), // 🔥 Keeps UI clean on Web
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // APP LOGO
                Image.asset(
                  'assets/icon/fincell_icon.png',
                  height: 100,
                  errorBuilder: (context, error, stackTrace) {
                    return const Icon(
                      Icons.phone_android,
                      size: 80,
                      color: Colors.blue,
                    );
                  },
                ),
                const SizedBox(height: 10),
                const Text(
                  "FinCell",
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ), // 🔥 Black
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
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ), // 🔥 Black
                  ),
                ),
                const SizedBox(height: 20),

                // EMAIL FIELD
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(
                    color: Colors.black,
                  ), // 🔥 Input text black
                  decoration: InputDecoration(
                    labelText: "Email address",
                    labelStyle: const TextStyle(color: Colors.black54),
                    prefixIcon: const Icon(
                      Icons.email_outlined,
                      color: Colors.blue,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // PASSWORD FIELD
                TextField(
                  controller: _passwordController,
                  obscureText: obscurePassword,
                  onChanged: _validatePassword,
                  style: const TextStyle(
                    color: Colors.black,
                  ), // 🔥 Input text black
                  decoration: InputDecoration(
                    labelText: isLogin ? "Password" : "Create password",
                    labelStyle: const TextStyle(color: Colors.black54),
                    prefixIcon: const Icon(
                      Icons.lock_outline,
                      color: Colors.blue,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                        color: Colors.grey,
                      ),
                      onPressed: () =>
                          setState(() => obscurePassword = !obscurePassword),
                    ),
                  ),
                ),

                // PASSWORD RULES
                if (!isLogin) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Requirements:",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.black,
                          ),
                        ),
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

                if (error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // SUBMIT BUTTON
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xff1E88E5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isLoading ? null : _submit,
                    child: isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(
                            isLogin ? "Login" : "Create Account",
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 15),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      isLogin ? "New user?" : "Already have an account?",
                      style: const TextStyle(color: Colors.black54),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        isLogin = !isLogin;
                        error = "";
                      }),
                      child: Text(
                        isLogin ? "Create account" : "Login",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xff1E88E5),
                        ),
                      ),
                    ),
                  ],
                ),

                if (isLogin)
                  TextButton(
                    onPressed: _forgotPassword,
                    child: const Text(
                      "Forgot Password?",
                      style: TextStyle(color: Colors.black45),
                    ),
                  ),

                const SizedBox(height: 20),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text("OR", style: TextStyle(color: Colors.grey)),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 20),

                // GOOGLE LOGIN BUTTON WITH OFFICIAL GOOGLE LOGO
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: Colors.black12, width: 1.2),
                      elevation: 0,
                    ),
                    icon: const GoogleBrandLogo(size: 22),
                    label: const Text(
                      "Continue with Google",
                      style: TextStyle(
                        color: Colors.black87,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                    onPressed: isLoading ? null : _googleLogin,
                  ),
                ),

                const SizedBox(height: 12),

                // GUEST LOGIN BUTTON
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: Colors.black12, width: 1.2),
                      elevation: 0,
                    ),
                    icon: const Icon(
                      Icons.person_outline,
                      color: Colors.black87,
                      size: 22,
                    ),
                    label: const Text(
                      "Continue as Guest",
                      style: TextStyle(
                        color: Colors.black87,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                    onPressed: isLoading ? null : _guestLogin,
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

/// Dynamically renders the official Google brand logo.
/// Connects directly to Google's official CDN (`gstatic`) so any visual or branding
/// updates published by Google are automatically fetched and reflected live.
/// Seamlessly falls back to the high-resolution local asset if offline.
class GoogleBrandLogo extends StatelessWidget {
  final double size;
  const GoogleBrandLogo({super.key, this.size = 22});

  static const String _officialGoogleCdnUrl =
      'https://www.gstatic.com/images/branding/product/2x/googleg_96dp.png';

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.network(
        _officialGoogleCdnUrl,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Image.asset(
            'assets/icon/google_logo.png',
            width: size,
            height: size,
            fit: BoxFit.contain,
          );
        },
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Image.asset(
            'assets/icon/google_logo.png',
            width: size,
            height: size,
            fit: BoxFit.contain,
          );
        },
      ),
    );
  }
}
