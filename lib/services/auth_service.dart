import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {

  final FirebaseAuth _auth = FirebaseAuth.instance;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
    serverClientId: '1045725821597-70voe1tbd50a73gdvkg8ediu66qrk79s.apps.googleusercontent.com',
  );

  // ================= GOOGLE SIGN IN =================

  Future<User?> signInWithGoogle() async {
    try {
      UserCredential userCredential;

      // ===== WEB LOGIN =====
      if (kIsWeb) {
        final GoogleAuthProvider googleProvider = GoogleAuthProvider();
        googleProvider.addScope('email');
        googleProvider.addScope('profile');
        userCredential = await _auth.signInWithPopup(googleProvider);
      } else {
        // ===== MOBILE LOGIN =====
        try {
          await _googleSignIn.signOut();
        } catch (_) {}

        final googleUser = await _googleSignIn.signIn();

        if (googleUser == null) {
          // User dismissed or cancelled the Google Sign-In prompt
          return null;
        }

        final googleAuth = await googleUser.authentication;

        if (googleAuth.accessToken == null && googleAuth.idToken == null) {
          throw FirebaseAuthException(
            code: "TOKEN_ERROR",
            message: "Google authentication failed to receive credentials",
          );
        }

        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );

        userCredential = await _auth.signInWithCredential(credential);
      }

      final user = userCredential.user;

      if (user == null) return null;

      await ensureUserDocument(user);

      return user;
    } on FirebaseAuthException catch (e) {
      debugPrint("Firebase Auth error during Google sign-in: ${e.code} - ${e.message}");
      rethrow;
    } catch (e) {
      debugPrint("Google sign-in exception: $e");
      final errStr = e.toString();
      final message = errStr.contains("ApiException: 10")
          ? "Google Play Services configuration error (Code 10). Ensure SHA-1 fingerprint is registered."
          : (errStr.contains("ApiException: 12500")
              ? "Google Sign-In error (Code 12500). Please try again."
              : "Google Sign-In failed: $e");
      throw FirebaseAuthException(
        code: "GOOGLE_LOGIN_FAILED",
        message: message,
      );
    }
  }

  // ================= GUEST SIGN IN =================

  Future<User?> signInAnonymously() async {
    try {
      final userCredential = await _auth.signInAnonymously();
      final user = userCredential.user;

      if (user == null) return null;

      await ensureUserDocument(user);

      return user;
    } on FirebaseAuthException catch (e) {
      debugPrint("Firebase Auth error during guest sign-in: ${e.code} - ${e.message}");
      rethrow;
    } catch (e) {
      debugPrint("Guest sign-in exception: $e");
      throw FirebaseAuthException(
        code: "GUEST_LOGIN_FAILED",
        message: "Guest sign-in failed: $e",
      );
    }
  }

  // ================= ENSURE USER DOC =================

  static Future<void> ensureUserDocument(User user) async {

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    final doc = await userRef.get();
    final isGuest = user.isAnonymous;

    if (!doc.exists) {

      final Map<String, dynamic> initialData = {
        'name': isGuest
            ? "Guest User"
            : (user.displayName ?? user.email?.split('@')[0] ?? ""),
        'email': isGuest ? null : user.email?.toLowerCase(),
        'isGuest': isGuest,
        'uniqueCode': null,
        'securityQuestion': null,
        'securityAnswer': null,
        'photoUrl': user.photoURL,
        'storageUsedBytes': 0,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // 15 GB quota is allocated ONLY to permanent registered users, NOT guest users
      if (!isGuest) {
        initialData['storageQuotaBytes'] = 16106127360;
      } else {
        initialData['storageQuotaBytes'] = 0;
      }

      await userRef.set(initialData);

    } else {

      final data = doc.data();
      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (!isGuest) {
        updates['email'] = user.email?.toLowerCase();
        if (data == null || !data.containsKey('storageQuotaBytes')) {
          updates['storageQuotaBytes'] = 16106127360;
        }
      }

      if (data == null || !data.containsKey('storageUsedBytes')) {
        updates['storageUsedBytes'] = 0;
      }

      await userRef.set(updates, SetOptions(merge: true));
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