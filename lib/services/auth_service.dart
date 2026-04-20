import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {

  final FirebaseAuth _auth = FirebaseAuth.instance;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email'],
  );

  // ================= GOOGLE SIGN IN =================

  Future<User?> signInWithGoogle() async {

    try {

      UserCredential userCredential;

      // ===== WEB LOGIN =====
      if (kIsWeb) {

        final GoogleAuthProvider googleProvider = GoogleAuthProvider();

        userCredential =
            await _auth.signInWithPopup(googleProvider);

      } else {

        // ===== MOBILE LOGIN =====

        await _googleSignIn.signOut();

        final googleUser = await _googleSignIn.signIn();

        if (googleUser == null) return null;

        final googleAuth = await googleUser.authentication;

        if (googleAuth.accessToken == null && googleAuth.idToken == null) {
          throw FirebaseAuthException(
            code: "TOKEN_ERROR",
            message: "Google authentication failed",
          );
        }

        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );

        userCredential =
            await _auth.signInWithCredential(credential);
      }

      final user = userCredential.user;

      if (user == null) return null;

      await _ensureUserDocument(user);

      return user;

    } on FirebaseAuthException {
      rethrow;
    } catch (e) {

      throw FirebaseAuthException(
        code: "GOOGLE_LOGIN_FAILED",
        message: "Google sign-in failed",
      );
    }
  }

  // ================= ENSURE USER DOC =================

  Future<void> _ensureUserDocument(User user) async {

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    final doc = await userRef.get();

    if (!doc.exists) {

      await userRef.set({
        'name': user.displayName ?? user.email?.split('@')[0] ?? "",
        'email': user.email?.toLowerCase(),
        'uniqueCode': null,
        'securityQuestion': null,
        'securityAnswer': null,
        'photoUrl': user.photoURL,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

    } else {

      await userRef.set({
        'email': user.email?.toLowerCase(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  // ================= SIGN OUT =================

  Future<void> signOut() async {

    try {

      if (!kIsWeb) {
        await _googleSignIn.signOut();
      }

      await _auth.signOut();

    } catch (_) {}
  }
}