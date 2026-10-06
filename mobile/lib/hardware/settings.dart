import '../core/storage/kv_store.dart';

enum DataSource { live, simulator }

/// Hardware-mode settings, kept on the device.
class HardwareSettings {
  HardwareSettings(this._store);

  static const defaultHost = '192.168.4.1';
  static const defaultPort = 81;

  /// Wi-Fi network the ESP32 creates (no internet).
  static const ssid = 'STMS-RSU';

  static const _kHost = 'hw_host';
  static const _kPort = 'hw_port';
  static const _kSource = 'hw_source';

  final KeyValueStore _store;

  String get host => _store.getString(_kHost) ?? defaultHost;
  int get port => int.tryParse(_store.getString(_kPort) ?? '') ?? defaultPort;
  DataSource get source => DataSource.values.asNameMap()[_store.getString(_kSource) ?? ''] ?? DataSource.live;

  Future<void> setAddress(String host, int port) async {
    await _store.setString(_kHost, host.trim());
    await _store.setString(_kPort, '$port');
  }

  Future<void> setSource(DataSource source) => _store.setString(_kSource, source.name);

  /// An IPv4 address or a host name, without scheme or port.
  static String? validateHost(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Enter the controller address, e.g. 192.168.4.1';
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(v);
    if (ipv4 != null) {
      final ok = [1, 2, 3, 4].every((i) => int.parse(ipv4.group(i)!) <= 255);
      return ok ? null : 'Each part of the address must be 0-255';
    }
    if (!RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$').hasMatch(v)) {
      return 'Enter only the address, like 192.168.4.1 (no ws://, no port)';
    }
    return null;
  }

  static String? validatePort(String value) {
    final p = int.tryParse(value.trim());
    if (p == null || p < 1 || p > 65535) return 'Port 1-65535';
    return null;
  }
}
