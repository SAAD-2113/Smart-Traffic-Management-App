import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native helpers for Hardware mode (implemented in android/.../MainActivity.java and
/// ios/Runner/AppDelegate.swift). Missing implementations (web, tests) are ignored.
class HardwarePlatform {
  const HardwarePlatform();

  static const _channel = MethodChannel('com.fyp.smart_traffic/hardware');

  bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _mobile => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Android: route this app's connections over Wi-Fi even though that network has no
  /// internet (otherwise Android may send them over mobile data). Stays in effect, and
  /// follows Wi-Fi reconnects, until [releaseWifi]. Returns whether Wi-Fi is bound now.
  Future<bool> bindToWifi() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('bindToWifi') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> releaseWifi() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('releaseWifi');
    } catch (_) {}
  }

  Future<bool> isBoundToWifi() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('isBoundToWifi') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Keeps the screen on while the hardware dashboard is open.
  Future<void> keepScreenOn(bool on) async {
    if (!_mobile) return;
    try {
      await _channel.invokeMethod<void>('keepScreenOn', {'on': on});
    } catch (_) {}
  }

  bool get supportsWifiBinding => _android;
}
