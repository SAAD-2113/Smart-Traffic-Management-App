import 'package:web/web.dart' as web;

import 'kv_store.dart';

Future<KeyValueStore> openStore() async => _LocalStorageStore();

class _LocalStorageStore implements KeyValueStore {
  static const _prefix = 'smart_traffic.';

  @override
  String? getString(String key) => web.window.localStorage.getItem('$_prefix$key');

  @override
  Future<void> setString(String key, String value) async => web.window.localStorage.setItem('$_prefix$key', value);

  @override
  Future<void> remove(String key) async => web.window.localStorage.removeItem('$_prefix$key');
}
