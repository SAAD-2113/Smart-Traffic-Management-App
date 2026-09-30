import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../storage/kv_store.dart';

/// Settings kept on the device: which backend to talk to, map tiles, theme and the
/// installation id that identifies this app install (not the person, not the vehicle).
class AppConfig extends ChangeNotifier {
  AppConfig(this._prefs);

  static const _kServerUrl = 'server_url';
  static const _kTileUrl = 'tile_url';
  static const _kThemeMode = 'theme_mode';
  static const _kInstallationId = 'installation_id';
  static const _kSelectedVehicle = 'selected_vehicle';

  /// Android emulator address of the host machine. Real phones need the PC's LAN address.
  static const defaultServerUrl = 'http://10.0.2.2:8000';
  static const defaultTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  final KeyValueStore _prefs;

  static Future<AppConfig> load([KeyValueStore? store]) async {
    final prefs = store ?? await KeyValueStore.open();
    final config = AppConfig(prefs);
    if ((prefs.getString(_kInstallationId) ?? '').isEmpty) {
      await prefs.setString(_kInstallationId, _newInstallationId());
    }
    return config;
  }

  static String _newInstallationId() {
    final rnd = Random.secure();
    final hex = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'app-$hex';
  }

  String get serverUrl => _prefs.getString(_kServerUrl) ?? (kIsWeb ? Uri.base.origin : defaultServerUrl);
  String get apiBaseUrl => '${serverUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1';
  String get tileUrl => _prefs.getString(_kTileUrl) ?? defaultTileUrl;
  String get installationId => _prefs.getString(_kInstallationId)!;
  String? get selectedVehicleId => _prefs.getString(_kSelectedVehicle);

  bool get isInsecureRemote {
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.scheme == 'https') return false;
    return !isPrivateHost(uri.host);
  }

  static bool isPrivateHost(String host) {
    if (host == 'localhost' || host == '10.0.2.2' || host.endsWith('.local')) return true;
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.contains(null)) return false;
    final a = parts[0]!, b = parts[1]!;
    return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  ThemeMode get themeMode => ThemeMode.values.firstWhere(
        (m) => m.name == _prefs.getString(_kThemeMode),
        orElse: () => ThemeMode.system,
      );

  /// Returns an error message, or null when the address is acceptable.
  static String? validateServerUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      return 'Enter an address like https://your-server.onrender.com or http://192.168.1.20:8000';
    }
    if (uri.path.isNotEmpty && uri.path != '/') return 'Enter only the server address, without a path';
    return null;
  }

  Future<void> setServerUrl(String value) async {
    await _prefs.setString(_kServerUrl, value.trim().replaceAll(RegExp(r'/+$'), ''));
    notifyListeners();
  }

  Future<void> setTileUrl(String value) async {
    await _prefs.setString(_kTileUrl, value.trim());
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_kThemeMode, mode.name);
    notifyListeners();
  }

  Future<void> setSelectedVehicle(String? vehicleId) async {
    if (vehicleId == null) {
      await _prefs.remove(_kSelectedVehicle);
    } else {
      await _prefs.setString(_kSelectedVehicle, vehicleId);
    }
    notifyListeners();
  }
}
