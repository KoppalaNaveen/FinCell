import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'auth/auth_gate.dart';
import 'services/background_service.dart';
import 'services/sync_manager.dart';
import 'services/ble_community_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔥 DO NOT wrap this in try-catch
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  BackgroundTracking.initializeNativeListener();
  SyncManager.instance.init();
  BLECommunityService.instance.startScanning();

  runApp(const FinCellApp());
}

class FinCellApp extends StatefulWidget {
  const FinCellApp({super.key});

  @override
  State<FinCellApp> createState() => _FinCellAppState();
}

class _FinCellAppState extends State<FinCellApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();

    _loadTheme();
  }

  // ================= THEME LOAD =================

  Future<void> _loadTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTheme = prefs.getString('themeMode');

      if (savedTheme == 'light') {
        _themeMode = ThemeMode.light;
      } else if (savedTheme == 'dark') {
        _themeMode = ThemeMode.dark;
      } else {
        _themeMode = ThemeMode.system;
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Theme load error: $e");
    }
  }

  // ================= THEME CHANGE =================

  Future<void> _changeTheme(ThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      switch (mode) {
        case ThemeMode.light:
          await prefs.setString('themeMode', 'light');
          break;
        case ThemeMode.dark:
          await prefs.setString('themeMode', 'dark');
          break;
        default:
          await prefs.setString('themeMode', 'system');
      }

      if (mounted) {
        setState(() {
          _themeMode = mode;
        });
      }
    } catch (e) {
      debugPrint("Theme change error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "FinCell",

      themeMode: _themeMode,

      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: Colors.blue,
        scaffoldBackgroundColor: Colors.grey[50],
      ),

      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),

      home: AuthGate(onThemeChanged: _changeTheme),

      routes: {
        '/login': (_) => AuthGate(onThemeChanged: _changeTheme),
        '/auth': (_) => AuthGate(onThemeChanged: _changeTheme),
      },
    );
  }
}
