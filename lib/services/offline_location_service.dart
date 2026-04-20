import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class OfflineLocationService {

  static Database? _db;

  static Future<Database> _initDB() async {

    if (_db != null) return _db!;

    final path = join(await getDatabasesPath(), 'locations.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) {
        return db.execute('''
          CREATE TABLE locations(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            latitude REAL,
            longitude REAL,
            timestamp TEXT
          )
        ''');
      },
    );

    return _db!;
  }

  static Future<void> saveLocation(
      double lat, double lng) async {

    final db = await _initDB();

    await db.insert('locations', {
      'latitude': lat,
      'longitude': lng,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getLocations() async {

    final db = await _initDB();

    return db.query('locations');
  }

  static Future<void> clearLocations() async {

    final db = await _initDB();

    await db.delete('locations');
  }
}