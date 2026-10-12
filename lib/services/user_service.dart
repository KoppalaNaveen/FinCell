import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'storage_quota_service.dart';

class UserService {
  static Future<void> saveUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (user.isAnonymous) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({
        'isGuest': true,
        'storageQuotaBytes': 0,
        'storageUsedBytes': 0,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return;
    }
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set({
      'email': user.email,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await StorageQuotaService.ensureUserStorageQuota(user.uid);
  }
}
