import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/storage/kv_store.dart';
import 'link/clock.dart';
import 'link/frame_source.dart';
import 'link/live_source.dart';
import 'link/simulator.dart';
import 'model/frame.dart';
import 'model/labels.dart';
import 'platform/hardware_platform.dart';
import 'settings.dart';

enum LinkStatus {
  /// A state frame arrived within the last 1.5 s.
  online,

  /// Connected, but no state frame for more than 1.5 s.
  stale,

  /// Socket closed (or simulator stopped).
  offline,
}

class LogEntry {
  LogEntry({required this.at, required this.title, this.detail, this.event, this.fromApp = false, this.simulated = false});

  /// Local time on this phone when the entry was received.
  final DateTime at;
  final String title;
  final String? detail;
  final String? event;

  /// Added by the app (e.g. "Controller restarted"), not sent by the controller.
  final bool fromApp;
  final bool simulated;
}

/// A shown "ev_request" popup.
class EvNotice {
  EvNotice(this.request, {required this.simulated});
  final EvRequest request;
  final bool simulated;
}

/// Read-only monitor of one ESP32 intersection. It receives frames and never sends anything.
///
/// Countdown: every state frame sets deadline = now + timing.remaining_ms (monotonic clock);
/// between frames the display is ceil((deadline - now) / 1000). When the link is STALE or
/// OFFLINE the display freezes at the moment data stopped: it never keeps counting without
/// fresh frames.
class HardwareMonitor extends ChangeNotifier {
  HardwareMonitor({
    required this.settings,
    MonoClock? clock,
    HardwarePlatform platform = const HardwarePlatform(),
    FrameSource Function(HardwareSettings settings)? createSource,
    this.statusCheckInterval = const Duration(milliseconds: 100),
  })  : clock = clock ?? SystemMonoClock(),
        _platform = platform, // ignore: prefer_initializing_formals
        _createSource = createSource ?? defaultSource;

  factory HardwareMonitor.forStore(KeyValueStore store) => HardwareMonitor(settings: HardwareSettings(store));

  static FrameSource defaultSource(HardwareSettings s) =>
      s.source == DataSource.simulator ? SimulatorSource() : LiveSource(LiveSource.uriFor(s.host, s.port));

  static const staleAfterMs = 1500;
  static const maxEvents = 20;
  static const noticeDuration = Duration(seconds: 5);

  final HardwareSettings settings;
  final MonoClock clock;
  final HardwarePlatform _platform;
  final FrameSource Function(HardwareSettings) _createSource;
  final Duration statusCheckInterval;

  FrameSource? _source;
  bool _open = false;
  int? _closedAt;
  int? _lastStateAt;
  int? _prevUptime;
  Timer? _statusTimer;
  LinkStatus _reportedStatus = LinkStatus.offline;

  /// Latest state; kept (and shown as "Last known state") when the link goes stale.
  HwState? state;

  /// The shown state came from the simulator (also after switching to the live source).
  bool stateFromSimulator = false;

  int? _deadline;
  int? _frameAt;
  int? _frameElapsed;
  int? _frameRemaining;

  final events = <LogEntry>[];
  EvNotice? notice;
  Timer? _noticeTimer;

  // Frames are numbered on arrival; warnings compare these numbers (two frames can arrive in
  // the same millisecond).
  int _received = 0;
  Object? unsupportedVersion;
  int? _unsupportedAt;
  String? unreadableReason;
  int? _unreadableAt;
  int? _lastValidAt;

  bool wifiBound = false;
  bool _disposed = false;

  // --- lifecycle -------------------------------------------------------------------------

  void start() {
    _platform.keepScreenOn(true);
    _platform.bindToWifi().then((bound) {
      if (_disposed) return;
      wifiBound = bound;
      notifyListeners();
    });
    _startSource();
    _statusTimer = Timer.periodic(statusCheckInterval, (_) => _checkStatus());
  }

  void _startSource() {
    final source = _createSource(settings);
    source.onFrame = handleText;
    source.onOpen = _handleOpen;
    _source = source;
    source.start();
  }

  void _stopSource() {
    final source = _source;
    if (source == null) return;
    source.stop(); // reports closed: the display freezes
    source
      ..onFrame = null
      ..onOpen = null;
    _source = null;
  }

  Future<void> setSource(DataSource source) async {
    if (source == settings.source && _source != null) return;
    await settings.setSource(source);
    _restartSource();
  }

  Future<void> setAddress(String host, int port) async {
    await settings.setAddress(host, port);
    if (settings.source == DataSource.live) _restartSource();
  }

  void _restartSource() {
    _stopSource();
    _prevUptime = null; // a different source is not a controller restart
    _startSource();
    notifyListeners();
  }

  Future<void> refreshWifiStatus() async {
    wifiBound = await _platform.isBoundToWifi();
    if (!_disposed) notifyListeners();
  }

  bool get supportsWifiBinding => _platform.supportsWifiBinding;

  @override
  void dispose() {
    _disposed = true;
    _stopSource();
    _statusTimer?.cancel();
    _noticeTimer?.cancel();
    _platform.keepScreenOn(false);
    _platform.releaseWifi();
    super.dispose();
  }

  // --- source info -----------------------------------------------------------------------

  bool get usingSimulator => _source?.isSimulator ?? settings.source == DataSource.simulator;
  String get sourceLabel => _source?.label ?? LiveSource.uriFor(settings.host, settings.port).toString();

  /// The simulator, for its test controls (mode button, link loss, emergency).
  HardwareSimulator? get simulator => switch (_source) {
        final SimulatorSource s => s.sim,
        _ => null,
      };

  /// "SIMULATED DATA" must be shown.
  bool get showSimulated => usingSimulator || (state != null && stateFromSimulator);

  // --- incoming frames -------------------------------------------------------------------

  void _handleOpen(bool open) {
    _open = open;
    if (!open) _closedAt = clock.nowMs();
    if (open && !usingSimulator && supportsWifiBinding) refreshWifiStatus();
    _checkStatus(force: true);
  }

  /// Handles one text frame (public for tests).
  void handleText(String text) {
    final now = clock.nowMs();
    final n = ++_received;
    switch (parseFrame(text)) {
      case StateFrame(:final state):
        _lastValidAt = n;
        _onState(state, now);
      case EventFrame(:final event):
        _lastValidAt = n;
        _onEvent(event);
      case UnsupportedFrame(:final version):
        unsupportedVersion = version;
        _unsupportedAt = n;
        notifyListeners();
      case UnreadableFrame(:final reason):
        unreadableReason = reason;
        _unreadableAt = n;
        notifyListeners();
    }
  }

  void _onState(HwState s, int now) {
    final uptime = s.uptimeMs;
    if (uptime != null) {
      final prev = _prevUptime;
      if (prev != null && uptime < prev) {
        _log(LogEntry(
          at: DateTime.now(),
          title: 'Controller restarted',
          detail: 'Uptime went back from ${labelUptime(prev)} to ${labelUptime(uptime)}',
          fromApp: true,
          simulated: usingSimulator,
        ));
      }
      _prevUptime = uptime;
    }
    state = s;
    stateFromSimulator = usingSimulator;
    _lastStateAt = now;
    final remaining = s.timing.remainingMs;
    if (remaining != null) {
      // Re-anchor on every frame, whether the number goes up (green extended) or down.
      _deadline = now + max(0, remaining);
      _frameAt = now;
      _frameRemaining = max(0, remaining);
      _frameElapsed = s.timing.elapsedMs;
    } else {
      _deadline = _frameAt = _frameRemaining = _frameElapsed = null;
    }
    _reportedStatus = status;
    notifyListeners();
  }

  void _onEvent(HwEvent e) {
    _log(LogEntry(
      at: DateTime.now(),
      title: eventName(e.event),
      detail: e.detail,
      event: e.event,
      simulated: usingSimulator,
    ));
    if (e.event == 'ev_request') {
      notice = EvNotice(EvRequest.parse(e.detail), simulated: usingSimulator);
      _noticeTimer?.cancel();
      _noticeTimer = Timer(noticeDuration, dismissNotice);
    }
    notifyListeners();
  }

  void _log(LogEntry entry) {
    events.insert(0, entry);
    if (events.length > maxEvents) events.removeRange(maxEvents, events.length);
  }

  void dismissNotice() {
    _noticeTimer?.cancel();
    if (notice == null) return;
    notice = null;
    if (!_disposed) notifyListeners();
  }

  // --- link status and countdown -------------------------------------------------------

  LinkStatus get status {
    if (!_open) return LinkStatus.offline;
    final last = _lastStateAt;
    if (last == null || clock.nowMs() - last > staleAfterMs) return LinkStatus.stale;
    return LinkStatus.online;
  }

  bool get isLive => status == LinkStatus.online;

  /// A state is shown but it is not current.
  bool get showingLastKnown => state != null && !isLive;

  void _checkStatus({bool force = false}) {
    if (_disposed) return;
    final s = status;
    if (force || s != _reportedStatus) {
      _reportedStatus = s;
      notifyListeners();
    }
  }

  /// "Now" for the countdown: real time while frames are fresh, otherwise frozen at the moment
  /// the data stopped (1.5 s after the last frame, or when the socket closed if earlier).
  int get _displayNow {
    final now = clock.nowMs();
    final last = _lastStateAt;
    if (last == null) return now;
    var limit = last + staleAfterMs;
    final closed = _closedAt;
    if (closed != null && closed >= last) limit = min(limit, closed);
    return min(now, limit);
  }

  /// Milliseconds left in the current interval, as displayed.
  int? get remainingMs {
    final d = _deadline;
    return d == null ? null : max(0, d - _displayNow);
  }

  /// Large countdown: ceil(remaining / 1 s).
  int? get countdownS {
    final r = remainingMs;
    return r == null ? null : (r / 1000).ceil();
  }

  int? get elapsedMs {
    final e = _frameElapsed, at = _frameAt, r = _frameRemaining;
    if (e == null || at == null || r == null) return null;
    return (e + (_displayNow - at)).clamp(0, e + r);
  }

  /// Share of the current interval done, 0..1.
  double? get progress {
    final e = _frameElapsed, r = _frameRemaining, now = elapsedMs;
    if (e == null || r == null || now == null || e + r <= 0) return null;
    return (now / (e + r)).clamp(0.0, 1.0);
  }

  /// Time since the last state frame (real time, not frozen).
  int? get sinceLastFrameMs {
    final last = _lastStateAt;
    return last == null ? null : clock.nowMs() - last;
  }

  /// The most recent frame had an unsupported version (no valid frame since).
  bool get unsupportedWarning {
    final u = _unsupportedAt;
    return u != null && (_lastValidAt == null || u > _lastValidAt!);
  }

  bool get unreadableWarning {
    final u = _unreadableAt;
    return u != null && (_lastValidAt == null || u > _lastValidAt!);
  }

  static String labelUptime(int ms) => uptime(ms);
}
