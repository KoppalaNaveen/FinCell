import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class DeviceReadService {
  static Future<Map<String, dynamic>?> getDevice(
      String deviceId) async {

    final uid = FirebaseAuth.instance.currentUser!.uid;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('devices')
        .doc(deviceId)
        .get();

    return doc.data();
  }
}
