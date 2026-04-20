import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'login_page.dart';
import '../home/home_page.dart';

class AuthGate extends StatelessWidget {
  final Function(ThemeMode) onThemeChanged;

  const AuthGate({super.key, required this.onThemeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {

        // 🔄 LOADING
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;

        // ❌ NOT LOGGED IN
        if (user == null) {
          return const LoginPage();
        }

        // 🔥 IMPORTANT: reload user to get latest verification state
        return FutureBuilder(
          future: user.reload(),
          builder: (context, reloadSnapshot) {

            final refreshedUser = FirebaseAuth.instance.currentUser;

            // 🔐 EMAIL VERIFICATION CHECK
            if (refreshedUser != null &&
                refreshedUser.email != null &&
                !refreshedUser.emailVerified) {

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
                          "A verification link was sent to:\n${refreshedUser.email}",
                          textAlign: TextAlign.center,
                        ),

                        const SizedBox(height: 20),

                        ElevatedButton(
                          onPressed: () async {
                            await refreshedUser.sendEmailVerification();

                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("Verification email resent"),
                              ),
                            );
                          },
                          child: const Text("Resend Email"),
                        ),

                        const SizedBox(height: 10),

                        ElevatedButton(
                          onPressed: () async {
                            await refreshedUser.reload();

                            if (FirebaseAuth.instance.currentUser!.emailVerified) {
                              (context as Element).reassemble(); // refresh UI
                            }
                          },
                          child: const Text("I have verified"),
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

            // ✅ VERIFIED USER → GO HOME
            return HomePage(
              onThemeChanged: onThemeChanged,
            );
          },
        );
      },
    );
  }
}