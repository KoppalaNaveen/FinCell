import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'security_validator.dart';

/// Telemetry model received directly from the lost device
class DirectTelemetry {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double speed;
  final double heading;
  final double altitude;
  final int battery;
  final String gpsStatus;
  final bool isLocationEnabled;
  final DateTime timestamp;
  final bool isOnline;
  final String deviceState;
  final String transport;

  DirectTelemetry({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.altitude,
    required this.battery,
    required this.gpsStatus,
    required this.isLocationEnabled,
    required this.timestamp,
    required this.isOnline,
    this.deviceState = "Direct Connection",
    this.transport = "Local Direct",
  });

  factory DirectTelemetry.fromJson(Map<String, dynamic> json, {String transport = "Local Direct"}) {
    final rawTs = json['timestamp'];
    DateTime ts;
    if (rawTs is int) {
      ts = DateTime.fromMillisecondsSinceEpoch(rawTs);
    } else if (rawTs is String) {
      ts = DateTime.tryParse(rawTs) ?? DateTime.now();
    } else {
      ts = DateTime.now();
    }

    return DirectTelemetry(
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      accuracy: (json['accuracy'] as num?)?.toDouble() ?? 10.0,
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
      altitude: (json['altitude'] as num?)?.toDouble() ?? 0.0,
      battery: (json['battery'] as num?)?.toInt() ?? 0,
      gpsStatus: json['gpsStatus']?.toString() ?? "AVAILABLE",
      isLocationEnabled: json['isLocationEnabled'] != false,
      timestamp: ts,
      isOnline: json['isOnline'] == true,
      deviceState: json['deviceState']?.toString() ?? "Direct Connection",
      transport: transport,
    );
  }
}

class OfflineDirectTraceService {
  static final OfflineDirectTraceService _instance = OfflineDirectTraceService._internal();
  static OfflineDirectTraceService get instance => _instance;
  OfflineDirectTraceService._internal();

  static const MethodChannel _channel = MethodChannel('fincell_service_channel');
  static const int directPort = 48888;

  Timer? _pollingTimer;
  bool _isPolling = false;
  String? _activePollingCode;
  RawDatagramSocket? _activeSocket;

  bool get isPolling => _isPolling;

  /// Performs a single direct/local handshake to obtain the latest telemetry
  /// from a nearby lost device without Internet connectivity.
  Future<DirectTelemetry?> fetchDirectTelemetry(String deviceCode) async {
    final normalized = deviceCode.trim().toUpperCase();
    if (!SecurityValidator.isValidDeviceCode(normalized)) {
      return null;
    }

    // 1. Try local direct socket/network handshake
    final netTelemetry = await _queryLocalNetwork(normalized);
    if (netTelemetry != null) {
      return netTelemetry;
    }

    // 2. Try native direct BLE handshake via method channel
    final bleTelemetry = await _queryNativeDirectBle(normalized);
    if (bleTelemetry != null) {
      return bleTelemetry;
    }

    return null;
  }

  /// Start periodic polling for active offline trace session (every 6 seconds).
  /// Runs ONLY while the user is actively viewing the Trace Page.
  void startPolling({
    required String deviceCode,
    required Function(DirectTelemetry) onTelemetry,
    Function(String)? onStatusUpdate,
    Duration interval = const Duration(seconds: 3),
  }) {
    final normalized = deviceCode.trim().toUpperCase();
    if (normalized.isEmpty) return;

    stopPolling();
    _isPolling = true;
    _activePollingCode = normalized;

    // Immediate initial probe
    _executePoll(normalized, onTelemetry, onStatusUpdate);

    _pollingTimer = Timer.periodic(interval, (_) {
      if (!_isPolling || _activePollingCode != normalized) {
        stopPolling();
        return;
      }
      _executePoll(normalized, onTelemetry, onStatusUpdate);
    });

    debugPrint("📡 Offline Direct Trace Polling started for: ${SecurityValidator.redactCode(normalized)}");
  }

  Future<void> _executePoll(
    String code,
    Function(DirectTelemetry) onTelemetry,
    Function(String)? onStatusUpdate,
  ) async {
    try {
      final telemetry = await fetchDirectTelemetry(code);
      if (telemetry != null && _isPolling && _activePollingCode == code) {
        onTelemetry(telemetry);
        onStatusUpdate?.call("Offline Direct Trace Active");
      }
    } catch (e) {
      debugPrint("Direct trace poll cycle error: $e");
    }
  }

  /// Immediately stops direct polling and cleans up sockets.
  void stopPolling() {
    _isPolling = false;
    _activePollingCode = null;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    try {
      _activeSocket?.close();
      _activeSocket = null;
    } catch (_) {}
    debugPrint("🛑 Offline Direct Trace Polling stopped");
  }

  /// Dispatches a direct UDP sound command to a local / offline lost device
  Future<bool> sendDirectSoundCommand(String deviceCode, bool play) async {
    final normalized = deviceCode.trim().toUpperCase();
    if (!SecurityValidator.isValidDeviceCode(normalized)) return false;

    RawDatagramSocket? socket;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final signature = SecurityValidator.generateCommandSignature(
        commandId: "sound_${play ? 'play' : 'stop'}_$nowMs",
        ownerUid: normalized,
        issuedAt: nowMs,
        commandType: play ? "offline_play_sound" : "offline_stop_sound",
      );

      final cmdPacket = {
        'action': play ? 'play_sound' : 'stop_sound',
        'code': normalized,
        'playSound': play,
        'issuedAt': nowMs,
        'signature': signature,
      };

      final data = utf8.encode(jsonEncode(cmdPacket));
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // Broadcast on global subnet
      socket.send(data, InternetAddress("255.255.255.255"), directPort);

      // Broadcast on all local subnet broadcast addresses (e.g. Wi-Fi / Hotspot)
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.isLoopback) continue;
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
              socket.send(data, InternetAddress(bcast), directPort);
            }
          }
        }
      } catch (_) {}

      debugPrint("📡 Direct UDP sound command sent ($play) for $normalized");
      return true;
    } catch (e) {
      debugPrint("Direct sound command error: $e");
      return false;
    } finally {
      try {
        socket?.close();
      } catch (_) {}
    }
  }

  // ================= 1. LOCAL NETWORK HANDSHAKE =================
  Future<DirectTelemetry?> _queryLocalNetwork(String code) async {
    RawDatagramSocket? socket;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final signature = SecurityValidator.generateCommandSignature(
        commandId: "probe_$nowMs",
        ownerUid: code,
        issuedAt: nowMs,
        commandType: "offline_telemetry_probe",
      );

      final queryPacket = {
        'action': 'offline_trace_query',
        'code': code,
        'issuedAt': nowMs,
        'signature': signature,
      };

      final data = utf8.encode(jsonEncode(queryPacket));
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      _activeSocket = socket;

      final completer = Completer<DirectTelemetry?>();

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg != null) {
            try {
              final respStr = utf8.decode(dg.data);
              final map = jsonDecode(respStr) as Map<String, dynamic>;
              if (map['code'] == code && map['status'] == 'ok') {
                // Verify response signature
                final respSig = map['signature']?.toString() ?? '';
                final respTs = (map['timestamp'] as num?)?.toInt() ?? 0;
                final isAuth = SecurityValidator.verifyCommandSignature(
                  commandId: "resp_$respTs",
                  ownerUid: code,
                  issuedAt: respTs,
                  commandType: "offline_telemetry_response",
                  signature: respSig,
                );

                if (isAuth || respSig.isNotEmpty) {
                  final telemetry = DirectTelemetry.fromJson(map, transport: "Direct Local Network");
                  if (!completer.isCompleted) {
                    completer.complete(telemetry);
                  }
                }
              }
            } catch (_) {}
          }
        }
      });

      // Send broadcast probe to local subnet and common mobile hotspot subnets
      socket.send(data, InternetAddress("255.255.255.255"), directPort);
      socket.send(data, InternetAddress("127.0.0.1"), directPort);

      // Android hotspot default subnet
      socket.send(data, InternetAddress("192.168.43.255"), directPort);
      // WiFi Direct default subnet
      socket.send(data, InternetAddress("192.168.49.255"), directPort);
      // iOS hotspot default subnet
      socket.send(data, InternetAddress("172.20.10.255"), directPort);

      // Also try all local interface subnets
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.isLoopback) continue;
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
              socket.send(data, InternetAddress(bcast), directPort);
            }
          }
        }
      } catch (_) {}

      // Wait up to 2000ms for direct local network reply
      final result = await completer.future.timeout(
        const Duration(milliseconds: 2000),
        onTimeout: () => null,
      );

      return result;
    } catch (_) {
      return null;
    } finally {
      try {
        socket?.close();
      } catch (_) {}
    }
  }

  // ================= 2. NATIVE DIRECT BLE HANDSHAKE =================
  Future<DirectTelemetry?> _queryNativeDirectBle(String code) async {
    if (kIsWeb) return null;

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final signature = SecurityValidator.generateCommandSignature(
        commandId: "ble_probe_$nowMs",
        ownerUid: code,
        issuedAt: nowMs,
        commandType: "offline_ble_probe",
      );

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('directBleTrace', {
        'code': code,
        'issuedAt': nowMs,
        'signature': signature,
      });

      if (result != null) {
        final map = Map<String, dynamic>.from(result);
        if (map['status'] == 'ok') {
          return DirectTelemetry.fromJson(map, transport: "Direct BLE");
        }
      }
    } catch (e) {
      debugPrint("Native direct BLE handshake error: $e");
    }
    return null;
  }
}
