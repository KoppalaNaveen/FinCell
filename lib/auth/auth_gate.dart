import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'login_page.dart';
import '../home/home_page.dart';

class AuthGate extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;

  const AuthGate({super.key, required this.onThemeChanged});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _isReloading = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;

        if (user == null) {
          return const LoginPage();
        }

        if (user.email != null && !user.emailVerified) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.email, size: 80),
                    const SizedBox(height: 20),
                    const Text(
                      "Verify your email",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "A verification link was sent to:\n${user.email}",
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () async {
                        await user.sendEmailVerification();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Verification email resent"),
                            ),
                          );
                        }
                      },
                      child: const Text("Resend Email"),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: _isReloading
                          ? null
                          : () async {
                              setState(() => _isReloading = true);
                              try {
                                await user.reload();
                                final refreshed = FirebaseAuth.instance.currentUser;
                                if (refreshed?.emailVerified == true) {
                                  setState(() {});
                                }
                              } catch (_) {
                              } finally {
                                if (mounted) setState(() => _isReloading = false);
                              }
                            },
                      child: _isReloading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text("I have verified"),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () async {
                        await FirebaseAuth.instance.signOut();
                      },
                      child: const Text("Back to Login"),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return HomePage(
          onThemeChanged: widget.onThemeChanged,
        );
      },
    );
  }
}