import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The refresh token lives in the Android Keystore-backed secure storage.
/// The short-lived access token is kept in memory only.
class TokenStore {
  TokenStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const _kRefresh = 'refresh_token';
  final FlutterSecureStorage _storage;

  Future<String?> readRefreshToken() async {
    try {
      return await _storage.read(key: _kRefresh);
    } catch (_) {
      return null; // corrupted keystore entry (e.g. after a backup restore): treat as signed out
    }
  }

  Future<void> writeRefreshToken(String token) => _storage.write(key: _kRefresh, value: token);

  Future<void> clear() => _storage.delete(key: _kRefresh);
}
