import 'package:flutter/foundation.dart';

import '../core/storage/kv_store.dart';

/// The two ways the app can run.
/// - [hardware]: offline monitor for the physical ESP32 intersection. No login, no server.
/// - [software]: the full system (login, driver and manager apps) talking to the backend.
enum AppMode { hardware, software }

/// Which mode is open, and whether the choice is remembered for the next launch.
class AppModeController extends ChangeNotifier {
  AppModeController(this._store) {
    remember = _store.getString(_kRemember) == 'true';
    if (remember) _mode = AppMode.values.asNameMap()[_store.getString(_kMode) ?? ''];
  }

  static const _kMode = 'app_mode';
  static const _kRemember = 'app_mode_remember';

  final KeyValueStore _store;
  AppMode? _mode;

  /// State of the "Remember my choice" checkbox.
  late bool remember;

  /// The open mode; null shows the mode selection screen.
  AppMode? get mode => _mode;

  Future<void> choose(AppMode mode, {required bool remember}) async {
    this.remember = remember;
    await _store.setString(_kRemember, remember ? 'true' : 'false');
    if (remember) {
      await _store.setString(_kMode, mode.name);
    } else {
      await _store.remove(_kMode);
    }
    _mode = mode;
    notifyListeners();
  }

  /// Back to the selection screen. The remembered mode is cleared so the next launch asks again
  /// until a mode is chosen; the checkbox keeps its state.
  Future<void> switchMode() async {
    await _store.remove(_kMode);
    _mode = null;
    notifyListeners();
  }
}
