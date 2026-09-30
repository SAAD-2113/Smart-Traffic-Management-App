import 'kv_store_io.dart' if (dart.library.js_interop) 'kv_store_web.dart' as impl;

/// Small persistent key-value store for app settings.
/// Android: a SQLite table. Web (manager dashboard): browser localStorage.
abstract class KeyValueStore {
  static Future<KeyValueStore> open() => impl.openStore();

  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// In-memory implementation for tests.
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore([Map<String, String>? initial]) : _values = {...?initial};
  final Map<String, String> _values;

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> setString(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);
}
