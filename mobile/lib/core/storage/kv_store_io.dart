import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'kv_store.dart';

Future<KeyValueStore> openStore() async {
  final db = await openDatabase(
    p.join(await getDatabasesPath(), 'settings.db'),
    version: 1,
    onCreate: (db, _) => db.execute('CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)'),
  );
  final rows = await db.query('kv');
  return _SqliteStore(db, {for (final r in rows) r['key'] as String: r['value'] as String});
}

class _SqliteStore implements KeyValueStore {
  _SqliteStore(this._db, this._cache);
  final Database _db;
  final Map<String, String> _cache; // all settings are small; reads are synchronous

  @override
  String? getString(String key) => _cache[key];

  @override
  Future<void> setString(String key, String value) async {
    _cache[key] = value;
    await _db.insert('kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> remove(String key) async {
    _cache.remove(key);
    await _db.delete('kv', where: 'key = ?', whereArgs: [key]);
  }
}
