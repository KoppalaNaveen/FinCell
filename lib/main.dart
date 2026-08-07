import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'auth/auth_gate.dart';
import 'auth/login_page.dart';
import 'services/permission_service.dart';
// 🔥 ADD THIS IMPORT AT TOP
import 'services/background_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔥 DO NOT wrap this in try-catch
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
  );

  BackgroundTracking.initializeNativeListener();

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
    _initialSetup();
  }

  // ================= FIRST RUN SETUP =================

  Future<void> _initialSetup() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final isFirstRun = prefs.getBool('isFirstRun') ?? true;

      if (isFirstRun) {
        await PermissionService.requestLocationPermissionsProperly();
        await PermissionService.requestDisableBatteryOptimization();
        await prefs.setBool('isFirstRun', false);
      }
    } catch (e) {
      debugPrint("Initial setup error: $e");
    }
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
        '/login': (_) => const LoginPage(),
        '/auth': (_) => AuthGate(onThemeChanged: _changeTheme),
      },
    );
  }
}
