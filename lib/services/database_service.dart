import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:convert';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'presence_tracker.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE api_cache (
            key TEXT PRIMARY KEY,
            data TEXT,
            updated_at INTEGER
          )
        ''');
      },
    );
  }

  /// Store JSON data in cache
  Future<void> saveCache(String key, dynamic data) async {
    final db = await database;
    await db.insert(
      'api_cache',
      {
        'key': key,
        'data': jsonEncode(data),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Retrieve JSON data from cache
  Future<dynamic> getCache(String key) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'api_cache',
      where: 'key = ?',
      whereArgs: [key],
    );

    if (maps.isNotEmpty) {
      return jsonDecode(maps.first['data']);
    }
    return null;
  }

  /// Clear specific cache
  Future<void> clearCache(String key) async {
    final db = await database;
    await db.delete('api_cache', where: 'key = ?', whereArgs: [key]);
  }

  /// Clear all cache
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('api_cache');
  }
}
