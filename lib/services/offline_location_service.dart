import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class EncryptedLocationRecord {
  final int id;
  final double latitude;
  final double longitude;
  final double speed;
  final double heading;
  final double accuracy;
  final double altitude;
  final int battery;
  final String timestamp;
  final String networkType;
  final String gpsStatus;
  final int riskScore;
  final bool isSynced;
  final int createdAt;
  final int retryCount;

  EncryptedLocationRecord({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.heading,
    required this.accuracy,
    required this.altitude,
    required this.battery,
    required this.timestamp,
    required this.networkType,
    required this.gpsStatus,
    required this.riskScore,
    required this.isSynced,
    required this.createdAt,
    required this.retryCount,
  });
}

class EncryptedTimelineRecord {
  final int id;
  final String eventType;
  final String title;
  final String description;
  final String timestamp;
  final double? lat;
  final double? lng;
  final int? battery;
  final double? speed;
  final int? riskScore;
  final bool isSynced;
  final int createdAt;
  final int retryCount;

  EncryptedTimelineRecord({
    required this.id,
    required this.eventType,
    required this.title,
    required this.description,
    required this.timestamp,
    this.lat,
    this.lng,
    this.battery,
    this.speed,
    this.riskScore,
    required this.isSynced,
    required this.createdAt,
    required this.retryCount,
  });
}

class EncryptedCommandRecord {
  final int id;
  final String commandId;
  final String commandType;
  final String status;
  final String payloadJson;
  final int startedAt;
  final int completedAt;
  final int timeoutSeconds;
  final String failureReason;
  final bool isSynced;
  final int createdAt;
  final int retryCount;

  EncryptedCommandRecord({
    required this.id,
    required this.commandId,
    required this.commandType,
    required this.status,
    required this.payloadJson,
    required this.startedAt,
    required this.completedAt,
    required this.timeoutSeconds,
    required this.failureReason,
    required this.isSynced,
    required this.createdAt,
    required this.retryCount,
  });
}

class EncryptedWifiRecord {
  final int id;
  final String ssid;
  final String bssid;
  final int signalStrength;
  final int frequency;
  final double? latitude;
  final double? longitude;
  final String timestamp;
  final bool isSynced;
  final int createdAt;

  EncryptedWifiRecord({
    required this.id,
    required this.ssid,
    required this.bssid,
    required this.signalStrength,
    required this.frequency,
    this.latitude,
    this.longitude,
    required this.timestamp,
    required this.isSynced,
    required this.createdAt,
  });
}

class EncryptedCellRecord {
  final int id;
  final int cellId;
  final int lac;
  final int mcc;
  final int mnc;
  final int signalStrength;
  final String timestamp;
  final bool isSynced;
  final int createdAt;

  EncryptedCellRecord({
    required this.id,
    required this.cellId,
    required this.lac,
    required this.mcc,
    required this.mnc,
    required this.signalStrength,
    required this.timestamp,
    required this.isSynced,
    required this.createdAt,
  });
}

class OfflineLocationService {
  static Database? _db;
  static String? _masterKey;

  static const int maxRecordsLimit = 5000;
  static const int maxDbSizeBytes = 100 * 1024 * 1024; // 100 MB

  // ================= ENCRYPTION KEY MANAGEMENT & KEYSTORE SECURITY =================
  static Future<String> _getOrGenerateMasterKey() async {
    if (_masterKey != null) return _masterKey!;
    final prefs = await SharedPreferences.getInstance();
    String? key = prefs.getString('fincell_db_enc_key_secure_v2');
    if (key == null || key.isEmpty) {
      final rand = Random.secure();
      final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
      final hmac = Hmac(sha256, utf8.encode("FinCell_Keystore_Salt_2026"));
      final derivedKey = hmac.convert(bytes).toString();
      key = base64UrlEncode(utf8.encode(derivedKey));
      await prefs.setString('fincell_db_enc_key_secure_v2', key);
    }
    _masterKey = key;
    return _masterKey!;
  }

  static String _encryptPayload(String input, String keyStr) {
    if (input.isEmpty) return input;
    final inputBytes = utf8.encode(input);
    final keyBytes = utf8.encode(keyStr);
    final result = List<int>.generate(inputBytes.length, (i) {
      return inputBytes[i] ^ keyBytes[i % keyBytes.length];
    });
    return base64UrlEncode(result);
  }

  static String _decryptPayload(String ciphertext, String keyStr) {
    if (ciphertext.isEmpty) return ciphertext;
    try {
      final cipherBytes = base64Url.decode(ciphertext);
      final keyBytes = utf8.encode(keyStr);
      final result = List<int>.generate(cipherBytes.length, (i) {
        return cipherBytes[i] ^ keyBytes[i % keyBytes.length];
      });
      return utf8.decode(result);
    } catch (_) {
      return ciphertext; // Fallback plain text if unencrypted
    }
  }

  // ================= DATABASE INIT =================
  static Future<Database> _initDB() async {
    if (_db != null && _db!.isOpen) return _db!;

    final dbPath = join(await getDatabasesPath(), 'fincell_encrypted.db');

    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _createTables(db);
      },
    );

    return _db!;
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS OfflineLocations(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        latitude REAL,
        longitude REAL,
        speed REAL,
        heading REAL,
        accuracy REAL,
        altitude REAL,
        battery INTEGER,
        timestamp TEXT,
        network_type TEXT,
        gps_status TEXT,
        risk_score INTEGER,
        is_synced INTEGER DEFAULT 0,
        created_at INTEGER,
        retry_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS OfflineTimeline(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_type TEXT,
        title TEXT,
        description TEXT,
        timestamp TEXT,
        lat REAL,
        lng REAL,
        battery INTEGER,
        speed REAL,
        risk_score INTEGER,
        is_synced INTEGER DEFAULT 0,
        created_at INTEGER,
        retry_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS PendingCommands(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        command_id TEXT UNIQUE,
        command_type TEXT,
        status TEXT,
        payload TEXT,
        started_at INTEGER DEFAULT 0,
        completed_at INTEGER DEFAULT 0,
        timeout_seconds INTEGER DEFAULT 60,
        failure_reason TEXT,
        is_synced INTEGER DEFAULT 0,
        created_at INTEGER,
        retry_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS WifiScans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ssid TEXT,
        bssid TEXT,
        signal_strength INTEGER,
        frequency INTEGER,
        latitude REAL,
        longitude REAL,
        timestamp TEXT,
        is_synced INTEGER DEFAULT 0,
        created_at INTEGER,
        retry_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS BluetoothScans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_name TEXT,
        mac_address TEXT,
        rssi INTEGER,
        timestamp TEXT,
        is_synced INTEGER DEFAULT 0,
        created_at INTEGER,
        retry_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS CellTowerData(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cell_id INTEGER,
        lac INTEGER,
        mcc INTEGER,
        mnc INTEGER,
        signal_strength INTEGER,
        timestamp TEXT,
        is_synced INTEGER DEFAULT 0,
        created_at INTEGER,
        retry_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS SyncQueue(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        data_type TEXT,
        record_id INTEGER,
        status TEXT,
        retry_count INTEGER DEFAULT 0,
        last_attempt INTEGER,
        error_message TEXT
      )
    ''');
  }

  // ================= MODULE 1: LOCATION CACHE =================
  static Future<int> saveLocation(
    double lat,
    double lng, {
    double speed = 0.0,
    double heading = 0.0,
    double accuracy = 0.0,
    double altitude = 0.0,
    int battery = 0,
    String networkType = "UNKNOWN",
    String gpsStatus = "AVAILABLE",
    int riskScore = 0,
  }) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();
      final now = DateTime.now();

      final id = await db.insert('OfflineLocations', {
        'latitude': lat,
        'longitude': lng,
        'speed': speed,
        'heading': heading,
        'accuracy': accuracy,
        'altitude': altitude,
        'battery': battery,
        'timestamp': _encryptPayload(now.toIso8601String(), key),
        'network_type': _encryptPayload(networkType, key),
        'gps_status': _encryptPayload(gpsStatus, key),
        'risk_score': riskScore,
        'is_synced': 0,
        'created_at': now.millisecondsSinceEpoch,
        'retry_count': 0,
      });

      await autoCleanUp();
      return id;
    } catch (e) {
      debugPrint("Offline location save error: $e");
      return -1;
    }
  }

  /// Legacy backward-compatibility method
  static Future<List<Map<String, dynamic>>> getLocations() async {
    final list = await getUnsyncedLocations();
    return list.map((rec) => {
      'id': rec.id,
      'latitude': rec.latitude,
      'longitude': rec.longitude,
      'timestamp': rec.timestamp,
    }).toList();
  }

  /// Legacy backward-compatibility method
  static Future<void> clearLocations() async {
    await clearAll();
  }

  static Future<List<EncryptedLocationRecord>> getUnsyncedLocations({int limit = 100}) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();

      final maps = await db.query(
        'OfflineLocations',
        where: 'is_synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
        limit: limit,
      );

      return maps.map((m) {
        return EncryptedLocationRecord(
          id: m['id'] as int,
          latitude: (m['latitude'] as num).toDouble(),
          longitude: (m['longitude'] as num).toDouble(),
          speed: (m['speed'] as num? ?? 0.0).toDouble(),
          heading: (m['heading'] as num? ?? 0.0).toDouble(),
          accuracy: (m['accuracy'] as num? ?? 0.0).toDouble(),
          altitude: (m['altitude'] as num? ?? 0.0).toDouble(),
          battery: (m['battery'] as num? ?? 0).toInt(),
          timestamp: _decryptPayload(m['timestamp'] as String? ?? '', key),
          networkType: _decryptPayload(m['network_type'] as String? ?? 'UNKNOWN', key),
          gpsStatus: _decryptPayload(m['gps_status'] as String? ?? 'AVAILABLE', key),
          riskScore: (m['risk_score'] as num? ?? 0).toInt(),
          isSynced: (m['is_synced'] as int? ?? 0) == 1,
          createdAt: (m['created_at'] as int? ?? 0),
          retryCount: (m['retry_count'] as int? ?? 0),
        );
      }).toList();
    } catch (e) {
      debugPrint("Get unsynced locations error: $e");
      return [];
    }
  }

  /// Retrieves the most recent cached location record from local SQLite DB
  static Future<EncryptedLocationRecord?> getLastCachedLocationRecord() async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();

      final maps = await db.query(
        'OfflineLocations',
        orderBy: 'created_at DESC',
        limit: 1,
      );

      if (maps.isEmpty) return null;
      final m = maps.first;

      return EncryptedLocationRecord(
        id: m['id'] as int,
        latitude: (m['latitude'] as num).toDouble(),
        longitude: (m['longitude'] as num).toDouble(),
        speed: (m['speed'] as num? ?? 0.0).toDouble(),
        heading: (m['heading'] as num? ?? 0.0).toDouble(),
        accuracy: (m['accuracy'] as num? ?? 0.0).toDouble(),
        altitude: (m['altitude'] as num? ?? 0.0).toDouble(),
        battery: (m['battery'] as num? ?? 0).toInt(),
        timestamp: _decryptPayload(m['timestamp'] as String? ?? '', key),
        networkType: _decryptPayload(m['network_type'] as String? ?? 'UNKNOWN', key),
        gpsStatus: _decryptPayload(m['gps_status'] as String? ?? 'AVAILABLE', key),
        riskScore: (m['risk_score'] as num? ?? 0).toInt(),
        isSynced: (m['is_synced'] as int? ?? 0) == 1,
        createdAt: (m['created_at'] as int? ?? 0),
        retryCount: (m['retry_count'] as int? ?? 0),
      );
    } catch (e) {
      debugPrint("Get last cached location error: $e");
      return null;
    }
  }

  static Future<void> markLocationsSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await _initDB();
      final idStr = ids.join(',');
      await db.rawUpdate('UPDATE OfflineLocations SET is_synced = 1 WHERE id IN ($idStr)');
      await autoCleanUp();
    } catch (e) {
      debugPrint("Mark locations synced error: $e");
    }
  }

  // ================= MODULE 4: OFFLINE TIMELINE =================
  static Future<int> saveTimelineEvent({
    required String eventType,
    required String title,
    required String description,
    double? lat,
    double? lng,
    int? battery,
    double? speed,
    int? riskScore,
  }) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();
      final now = DateTime.now();

      return await db.insert('OfflineTimeline', {
        'event_type': _encryptPayload(eventType, key),
        'title': _encryptPayload(title, key),
        'description': _encryptPayload(description, key),
        'timestamp': _encryptPayload(now.toIso8601String(), key),
        'lat': lat,
        'lng': lng,
        'battery': battery,
        'speed': speed,
        'risk_score': riskScore,
        'is_synced': 0,
        'created_at': now.millisecondsSinceEpoch,
        'retry_count': 0,
      });
    } catch (e) {
      debugPrint("Save timeline event error: $e");
      return -1;
    }
  }

  static Future<List<EncryptedTimelineRecord>> getUnsyncedTimeline({int limit = 100}) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();

      final maps = await db.query(
        'OfflineTimeline',
        where: 'is_synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
        limit: limit,
      );

      return maps.map((m) {
        return EncryptedTimelineRecord(
          id: m['id'] as int,
          eventType: _decryptPayload(m['event_type'] as String? ?? 'SYSTEM_EVENT', key),
          title: _decryptPayload(m['title'] as String? ?? 'Security Event', key),
          description: _decryptPayload(m['description'] as String? ?? '', key),
          timestamp: _decryptPayload(m['timestamp'] as String? ?? '', key),
          lat: (m['lat'] as num?)?.toDouble(),
          lng: (m['lng'] as num?)?.toDouble(),
          battery: (m['battery'] as num?)?.toInt(),
          speed: (m['speed'] as num?)?.toDouble(),
          riskScore: (m['risk_score'] as num?)?.toInt(),
          isSynced: (m['is_synced'] as int? ?? 0) == 1,
          createdAt: (m['created_at'] as int? ?? 0),
          retryCount: (m['retry_count'] as int? ?? 0),
        );
      }).toList();
    } catch (e) {
      debugPrint("Get unsynced timeline error: $e");
      return [];
    }
  }

  static Future<void> markTimelineSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await _initDB();
      final idStr = ids.join(',');
      await db.rawUpdate('UPDATE OfflineTimeline SET is_synced = 1 WHERE id IN ($idStr)');
      await autoCleanUp();
    } catch (e) {
      debugPrint("Mark timeline synced error: $e");
    }
  }

  // ================= MODULE 5: PENDING COMMAND QUEUE =================
  static Future<int> queueCommand({
    required String commandId,
    required String commandType,
    required Map<String, dynamic> payload,
    int timeoutSeconds = 60,
  }) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();
      final now = DateTime.now().millisecondsSinceEpoch;

      return await db.insert('PendingCommands', {
        'command_id': commandId,
        'command_type': _encryptPayload(commandType, key),
        'status': _encryptPayload('Pending', key),
        'payload': _encryptPayload(jsonEncode(payload), key),
        'started_at': 0,
        'completed_at': 0,
        'timeout_seconds': timeoutSeconds,
        'failure_reason': _encryptPayload('', key),
        'is_synced': 0,
        'created_at': now,
        'retry_count': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint("Queue command error: $e");
      return -1;
    }
  }

  static Future<List<EncryptedCommandRecord>> getPendingCommands() async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();

      final maps = await db.query(
        'PendingCommands',
        where: 'is_synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
      );

      return maps.map((m) {
        return EncryptedCommandRecord(
          id: m['id'] as int,
          commandId: m['command_id'] as String? ?? '',
          commandType: _decryptPayload(m['command_type'] as String? ?? '', key),
          status: _decryptPayload(m['status'] as String? ?? 'Pending', key),
          payloadJson: _decryptPayload(m['payload'] as String? ?? '{}', key),
          startedAt: (m['started_at'] as int? ?? 0),
          completedAt: (m['completed_at'] as int? ?? 0),
          timeoutSeconds: (m['timeout_seconds'] as int? ?? 60),
          failureReason: _decryptPayload(m['failure_reason'] as String? ?? '', key),
          isSynced: (m['is_synced'] as int? ?? 0) == 1,
          createdAt: (m['created_at'] as int? ?? 0),
          retryCount: (m['retry_count'] as int? ?? 0),
        );
      }).toList();
    } catch (e) {
      debugPrint("Get pending commands error: $e");
      return [];
    }
  }

  static Future<void> updateCommandStatus({
    required String commandId,
    required String status,
    String failureReason = '',
    bool markSynced = false,
  }) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();
      final now = DateTime.now().millisecondsSinceEpoch;

      final updateData = <String, dynamic>{
        'status': _encryptPayload(status, key),
        'failure_reason': _encryptPayload(failureReason, key),
        'completed_at': (status == 'Completed' || status == 'Failed') ? now : 0,
      };

      if (status == 'Running') {
        updateData['started_at'] = now;
      }

      if (markSynced) {
        updateData['is_synced'] = 1;
      }

      await db.update(
        'PendingCommands',
        updateData,
        where: 'command_id = ?',
        whereArgs: [commandId],
      );
    } catch (e) {
      debugPrint("Update command status error: $e");
    }
  }

  // ================= STORAGE DUAL-LIMIT AUTO CLEANUP =================
  static Future<void> autoCleanUp() async {
    try {
      final db = await _initDB();

      // 1. Delete synced location records if total count exceeds maxRecordsLimit
      final countResult = await db.rawQuery('SELECT COUNT(*) as c FROM OfflineLocations');
      final totalCount = Sqflite.firstIntValue(countResult) ?? 0;

      if (totalCount > maxRecordsLimit) {
        final excess = totalCount - maxRecordsLimit;
        await db.rawDelete('''
          DELETE FROM OfflineLocations WHERE id IN (
            SELECT id FROM OfflineLocations WHERE is_synced = 1 ORDER BY created_at ASC LIMIT $excess
          )
        ''');
      }

      // 2. Check DB file size; prune synced items if over maxDbSizeBytes
      final dbPath = join(await getDatabasesPath(), 'fincell_encrypted.db');
      final file = File(dbPath);
      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize > maxDbSizeBytes) {
          debugPrint("Offline DB size ($fileSize bytes) exceeds 100MB; pruning synced items...");
          await db.delete('OfflineLocations', where: 'is_synced = ?', whereArgs: [1]);
          await db.delete('OfflineTimeline', where: 'is_synced = ?', whereArgs: [1]);
          await db.delete('WifiScans', where: 'is_synced = ?', whereArgs: [1]);
          await db.delete('BluetoothScans', where: 'is_synced = ?', whereArgs: [1]);
          await db.delete('CellTowerData', where: 'is_synced = ?', whereArgs: [1]);
          await db.delete('PendingCommands', where: 'is_synced = ?', whereArgs: [1]);
        }
      }
    } catch (e) {
      debugPrint("Auto cleanup error: $e");
    }
  }

  // Helper count methods
  // ================= MODULE 6: WIFI FINGERPRINT CACHE =================
  static Future<int> saveWifiScan({
    required String ssid,
    required String bssid,
    required int signalStrength,
    required int frequency,
    double? latitude,
    double? longitude,
  }) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();
      final now = DateTime.now();

      return await db.insert('WifiScans', {
        'ssid': _encryptPayload(ssid.isEmpty ? '<unknown ssid>' : ssid, key),
        'bssid': _encryptPayload(bssid, key),
        'signal_strength': signalStrength,
        'frequency': frequency,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': _encryptPayload(now.toIso8601String(), key),
        'is_synced': 0,
        'created_at': now.millisecondsSinceEpoch,
        'retry_count': 0,
      });
    } catch (e) {
      debugPrint("Save Wifi scan error: $e");
      return -1;
    }
  }

  static Future<List<EncryptedWifiRecord>> getUnsyncedWifiScans({int limit = 100}) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();

      final maps = await db.query(
        'WifiScans',
        where: 'is_synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
        limit: limit,
      );

      return maps.map((m) {
        return EncryptedWifiRecord(
          id: m['id'] as int,
          ssid: _decryptPayload(m['ssid'] as String? ?? '<unknown ssid>', key),
          bssid: _decryptPayload(m['bssid'] as String? ?? '', key),
          signalStrength: (m['signal_strength'] as num? ?? 0).toInt(),
          frequency: (m['frequency'] as num? ?? 0).toInt(),
          latitude: (m['latitude'] as num?)?.toDouble(),
          longitude: (m['longitude'] as num?)?.toDouble(),
          timestamp: _decryptPayload(m['timestamp'] as String? ?? '', key),
          isSynced: (m['is_synced'] as int? ?? 0) == 1,
          createdAt: (m['created_at'] as int? ?? 0),
        );
      }).toList();
    } catch (e) {
      debugPrint("Get unsynced Wifi scans error: $e");
      return [];
    }
  }

  static Future<void> markWifiScansSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await _initDB();
      final idStr = ids.join(',');
      await db.rawUpdate('UPDATE WifiScans SET is_synced = 1 WHERE id IN ($idStr)');
      await autoCleanUp();
    } catch (e) {
      debugPrint("Mark Wifi scans synced error: $e");
    }
  }

  // ================= MODULE 7: CELL TOWER CACHE =================
  static Future<int> saveCellTowerData({
    required int cellId,
    required int lac,
    required int mcc,
    required int mnc,
    required int signalStrength,
  }) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();
      final now = DateTime.now();

      return await db.insert('CellTowerData', {
        'cell_id': cellId,
        'lac': lac,
        'mcc': mcc,
        'mnc': mnc,
        'signal_strength': signalStrength,
        'timestamp': _encryptPayload(now.toIso8601String(), key),
        'is_synced': 0,
        'created_at': now.millisecondsSinceEpoch,
        'retry_count': 0,
      });
    } catch (e) {
      debugPrint("Save Cell Tower data error: $e");
      return -1;
    }
  }

  static Future<List<EncryptedCellRecord>> getUnsyncedCellTowerData({int limit = 100}) async {
    try {
      final db = await _initDB();
      final key = await _getOrGenerateMasterKey();

      final maps = await db.query(
        'CellTowerData',
        where: 'is_synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
        limit: limit,
      );

      return maps.map((m) {
        return EncryptedCellRecord(
          id: m['id'] as int,
          cellId: (m['cell_id'] as num? ?? 0).toInt(),
          lac: (m['lac'] as num? ?? 0).toInt(),
          mcc: (m['mcc'] as num? ?? 0).toInt(),
          mnc: (m['mnc'] as num? ?? 0).toInt(),
          signalStrength: (m['signal_strength'] as num? ?? 0).toInt(),
          timestamp: _decryptPayload(m['timestamp'] as String? ?? '', key),
          isSynced: (m['is_synced'] as int? ?? 0) == 1,
          createdAt: (m['created_at'] as int? ?? 0),
        );
      }).toList();
    } catch (e) {
      debugPrint("Get unsynced Cell Tower data error: $e");
      return [];
    }
  }

  static Future<void> markCellTowerDataSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await _initDB();
      final idStr = ids.join(',');
      await db.rawUpdate('UPDATE CellTowerData SET is_synced = 1 WHERE id IN ($idStr)');
      await autoCleanUp();
    } catch (e) {
      debugPrint("Mark Cell Tower data synced error: $e");
    }
  }

  static Future<int> getUnsyncedCount() async {
    try {
      final db = await _initDB();
      final locCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM OfflineLocations WHERE is_synced = 0')) ?? 0;
      final timelineCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM OfflineTimeline WHERE is_synced = 0')) ?? 0;
      final wifiCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM WifiScans WHERE is_synced = 0')) ?? 0;
      final cellCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM CellTowerData WHERE is_synced = 0')) ?? 0;
      return locCount + timelineCount + wifiCount + cellCount;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clearAll() async {
    try {
      final db = await _initDB();
      await db.delete('OfflineLocations');
      await db.delete('OfflineTimeline');
      await db.delete('PendingCommands');
      await db.delete('WifiScans');
      await db.delete('BluetoothScans');
      await db.delete('CellTowerData');
      await db.delete('SyncQueue');
    } catch (e) {
      debugPrint("Clear all error: $e");
    }
  }
}