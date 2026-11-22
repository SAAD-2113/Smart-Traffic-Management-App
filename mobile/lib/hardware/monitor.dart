import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/storage/kv_store.dart';
import 'link/clock.dart';
import 'link/frame_source.dart';
import 'link/live_source.dart';
import 'link/simulator.dart';
import 'link/twin_source.dart';
import 'model/frame.dart';
import 'model/labels.dart';
import 'model/v3_view.dart';
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
class HardwareMonitor extends ChangeNotifier implements V3View {
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

  /// The simulator is the firmware v3 twin (v2i_core), the same format the hardware sends.
  static FrameSource defaultSource(HardwareSettings s) =>
      s.source == DataSource.simulator ? TwinSource() : LiveSource(LiveSource.uriFor(s.host, s.port));

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

  /// Latest Part-3 state; kept (and shown as "Last known state") when the link goes stale.
  HwState? state;

  /// Latest firmware v3 state. Exactly one of [state] and [v3] is set once data arrived: the
  /// one of the most recent state frame.
  @override
  V3State? v3;

  /// The controller sends firmware v3 frames: the dashboard shows the four-lane layout.
  bool get isV3 => v3 != null;

  @override
  String get countdownSource => usingSimulator ? 'Countdown from the simulator' : 'Countdown from the controller';

  /// MM:SS deadlines per lane (v3), monotonic ms.
  final _laneDeadline = <String, int>{};

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

  /// The Part-3 simulator, for its test controls (mode button, link loss, emergency).
  HardwareSimulator? get simulator => switch (_source) {
        final SimulatorSource s => s.sim,
        _ => null,
      };

  /// The firmware v3 twin, for its test controls (requested mode, vehicles, emergency).
  TwinSource? get twin => switch (_source) {
        final TwinSource t => t,
        _ => null,
      };

  /// Name of the intersection as the controller reports it.
  String? get intersectionLabel => isV3 ? v3?.intersection : state?.id;

  bool get hasState => state != null || v3 != null;

  /// "SIMULATED DATA" must be shown.
  bool get showSimulated => usingSimulator || (hasState && stateFromSimulator);

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
      case V3StateFrame(:final state):
        _lastValidAt = n;
        _onV3(state, now);
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

  /// Logs "Controller restarted" when the uptime goes back; returns true then.
  bool _checkRestart(int? uptime) {
    if (uptime == null) return false;
    final prev = _prevUptime;
    final restarted = prev != null && uptime < prev;
    if (restarted) {
      _log(LogEntry(
        at: DateTime.now(),
        title: 'Controller restarted',
        detail: 'Uptime went back from ${labelUptime(prev)} to ${labelUptime(uptime)}',
        fromApp: true,
        simulated: usingSimulator,
      ));
    }
    _prevUptime = uptime;
    return restarted;
  }

  void _onState(HwState s, int now) {
    _checkRestart(s.uptimeMs);
    state = s;
    v3 = null;
    _laneDeadline.clear();
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

  void _onV3(V3State s, int now) {
    final prev = v3;
    final up = s.uptimeS;
    final restarted = _checkRestart(up == null ? null : up * 1000);
    _deriveEvents(restarted ? null : prev, s); // no diff against the state from before a restart
    v3 = s;
    state = null;
    stateFromSimulator = usingSimulator;
    _lastStateAt = now;
    _laneDeadline.clear();
    for (final l in s.lanes) {
      final r = l.remS;
      if (r != null) _laneDeadline[l.lane] = now + max(0, (r * 1000).round());
    }
    final remaining = s.timing.remainingS;
    if (remaining != null) {
      final r = max(0, (remaining * 1000).round());
      _deadline = now + r;
      _frameAt = now;
      _frameRemaining = r;
      final e = s.timing.elapsedS;
      _frameElapsed = e == null ? null : max(0, (e * 1000).round());
    } else {
      _deadline = _frameAt = _frameRemaining = _frameElapsed = null;
    }
    _reportedStatus = status;
    notifyListeners();
  }

  /// Firmware v3 sends no event frames: the log is made from what changed between two states.
  void _deriveEvents(V3State? prev, V3State s) {
    if (prev == null) return;
    final sim = usingSimulator;
    void log(String title, String? detail, String event) =>
        _log(LogEntry(at: DateTime.now(), title: title, detail: detail, event: event, simulated: sim));

    // vehicles connected / removed by the controller (no packet for 3 s)
    final before = {for (final v in prev.vehicles) if (v.id != null) v.id!: v};
    final after = {for (final v in s.vehicles) if (v.id != null) v.id!: v};
    for (final v in after.values) {
      if (!before.containsKey(v.id)) {
        log('Vehicle ${v.id} connected', '${v.hw ?? dash} · ${v.isEmergency ? 'EMERGENCY' : 'normal'}', 'vehicle_conn');
      }
    }
    for (final v in before.values) {
      if (!after.containsKey(v.id)) log('Vehicle ${v.id} removed', 'No packet for 3 s (${v.hw ?? dash})', 'vehicle_lost');
    }
    if (s.requestedMode != prev.requestedMode) {
      log('Requested mode: ${modeName(s.requestedMode)}', 'Applies at the next lane decision', 'mode_change');
    }
    if (s.mode != prev.mode) log('Mode now ${modeName(s.mode)}', s.modeReason, 'mode_change');
    if (s.dataLost && !prev.dataLost) log('Vehicle data lost', s.modeReason, 'v2i_lost');

    if (s.emergencyLane != null && s.emergencyLane != prev.emergencyLane && s.priorityActive != true) {
      final e = s.emergencyOn(s.emergencyLane);
      final detail =
          'Lane ${s.emergencyLane}${e == null ? '' : ' · vehicle ${e.id}${e.distM == null ? '' : ' · ${e.distM!.toStringAsFixed(0)} m'}'}';
      log('Emergency vehicle: priority requested', detail, 'ev_request');
      _notify(EvRequest(vehicleId: e?.id?.toString(), approach: s.emergencyLane, result: 'requested', detail: detail));
    }
    if (s.priorityActive == true && prev.priorityActive != true) {
      final e = s.emergencyOn(s.cur);
      final detail = 'Lane ${orDash(s.cur)}${e == null ? '' : ' · vehicle ${e.id}'}';
      log('Emergency priority green', detail, 'preempt_start');
      _notify(EvRequest(vehicleId: e?.id?.toString(), approach: s.cur, result: 'granted', detail: detail));
    } else if (s.priorityActive != true && prev.priorityActive == true) {
      log('Priority green ended', 'Lane ${orDash(prev.cur)}', 'preempt_end');
    }

    if (s.cur != prev.cur || s.phase != prev.phase) {
      final t = s.timing;
      final String title;
      String? detail;
      if (s.phase == 'GREEN') {
        title = 'Lane ${orDash(s.cur)} GREEN';
        detail = '${t.targetGreenS == null ? dash : '${t.targetGreenS!.toStringAsFixed(1)} s'} · ${modeName(s.mode)}'
            '${t.priority == true ? ' · emergency priority' : ''}';
      } else if (s.phase == 'YELLOW') {
        title = 'Lane ${orDash(s.cur)} YELLOW';
      } else {
        title = s.phase == 'ALL_RED' ? 'ALL RED' : 'Phase ${orDash(s.phase)}';
      }
      log(title, detail, 'phase_change');
    }
  }

  void _notify(EvRequest r) {
    notice = EvNotice(r, simulated: usingSimulator);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(noticeDuration, dismissNotice);
  }

  void _onEvent(HwEvent e) {
    _log(LogEntry(
      at: DateTime.now(),
      title: eventName(e.event),
      detail: e.detail,
      event: e.event,
      simulated: usingSimulator,
    ));
    if (e.event == 'ev_request') _notify(EvRequest.parse(e.detail));
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

  @override
  bool get isLive => status == LinkStatus.online;

  /// A state is shown but it is not current.
  @override
  bool get showingLastKnown => hasState && !isLive;

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
  @override
  int? get remainingMs {
    final d = _deadline;
    return d == null ? null : max(0, d - _displayNow);
  }

  /// Large countdown: ceil(remaining / 1 s).
  @override
  int? get countdownS {
    final r = remainingMs;
    return r == null ? null : (r / 1000).ceil();
  }

  @override
  int? get elapsedMs {
    final e = _frameElapsed, at = _frameAt, r = _frameRemaining;
    if (e == null || at == null || r == null) return null;
    return (e + (_displayNow - at)).clamp(0, e + r);
  }

  /// Share of the current interval done, 0..1.
  @override
  double? get progress {
    final e = _frameElapsed, r = _frameRemaining, now = elapsedMs;
    if (e == null || r == null || now == null || e + r <= 0) return null;
    return (now / (e + r)).clamp(0.0, 1.0);
  }

  /// What a lane's MM:SS display shows (v3), counted down locally from the last frame's "rem"
  /// the way the firmware's TM1637 does: ceil(seconds - 0.001). Frozen like the countdown
  /// when the data stops. Null when unknown.
  @override
  String? laneDisplay(String lane) {
    final d = _laneDeadline[lane];
    if (d == null) return null;
    final ms = max(0, d - _displayNow);
    final total = (ms / 1000.0 - 0.001).ceil().clamp(0, 5999);
    return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
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
