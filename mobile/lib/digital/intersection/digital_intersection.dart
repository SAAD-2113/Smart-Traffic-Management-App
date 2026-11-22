import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../hardware/model/frame_v3.dart';
import '../../hardware/model/v3_view.dart';
import '../transport/links.dart';

/// A vehicle phone as the transport reports it (before or besides its packets).
class MemberInfo {
  MemberInfo({required this.online, required this.emergency});
  bool online;
  bool emergency;
}

/// This phone is the intersection: the firmware v3 controller (v2i_core) on a monotonic clock,
/// fed by the transport. It is the only authority for the signals; vehicles only show its ACKs.
///
/// The loop runs every [tick] (10 ms): density every 100 ms, expiry every 250 ms, the state
/// JSON every 500 ms (sent to the server for the host's other screens), like loop() on the ESP32.
class DigitalIntersection extends ChangeNotifier implements V3View {
  DigitalIntersection({
    required this.name,
    required double centerLat,
    required double centerLon,
    required this.link,
    v2i.MonoClock? clock,
    this.tick = const Duration(milliseconds: 10),
    this.uiEvery = const Duration(milliseconds: 100),
    this.useTimer = true,
    DateTime Function()? wallClock,
  }) : clock = clock ?? v2i.StopwatchClock() {
    controller = v2i.IntersectionController(
      clock: this.clock,
      geometry: v2i.Geometry(centerLat: centerLat, centerLon: centerLon),
      intersectionName: name,
      wallClock: wallClock ?? DateTime.now,
    );
  }

  final String name;
  final IntersectionLink link;
  final v2i.MonoClock clock;
  final Duration tick;
  final Duration uiEvery;

  /// False in tests: they call [step] themselves.
  final bool useTimer;

  late final v2i.IntersectionController controller;

  LinkState linkState = LinkState.connecting;
  String? linkReason;
  final members = <int, MemberInfo>{};

  /// Packet -> ACK round trip reported by each vehicle (ms), as measured on the vehicle.
  final rttMs = <int, int>{};
  int packetsIn = 0, acksOut = 0, statesOut = 0;
  bool running = false;
  Timer? _loop;
  int _lastUi = -1 << 40;
  V3State? _v3;

  v2i.V2ILog get log => controller.log;

  void start() {
    if (running) return;
    running = true;
    controller.onBroadcast = (state) {
      link.sendState(jsonEncode(state));
      statesOut++;
    };
    link
      ..onPacket = _onPacket
      ..onRtt = (vid, ms) {
        rttMs[vid] = ms;
        controller.reportRtt(vid, ms);
      }
      ..onMember = (vid, online, emergency) {
        members[vid] = MemberInfo(online: online, emergency: emergency);
        notifyListeners();
      }
      ..onState = (state, reason) {
        linkState = state;
        linkReason = reason;
        notifyListeners();
      };
    link.start();
    controller.start();
    _refresh();
    if (useTimer) _loop = Timer.periodic(tick, (_) => step());
  }

  void stop() {
    if (!running) return;
    running = false;
    _loop?.cancel();
    _loop = null;
    link.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// One pass of loop().
  void step() {
    controller.tick();
    final now = clock.nowMs();
    if (now - _lastUi >= uiEvery.inMilliseconds) {
      _lastUi = now;
      _refresh();
      notifyListeners();
    }
  }

  void _refresh() => _v3 = V3State.fromJson(controller.buildState());

  void _onPacket(int vid, String raw) {
    if (!running) return;
    packetsIn++;
    final ack = controller.processPacket(raw);
    if (ack != null) {
      link.sendAck(vid, ack);
      acksOut++;
    }
  }

  // --- commands (the firmware's Serial commands) -------------------------------------------

  /// "auto" | "fixed" | "adaptive"; applies at the next lane decision, like the firmware.
  void setRequestedMode(String mode) {
    controller.command(switch (mode) { 'fixed' => 'f', 'adaptive' => 'a', _ => 'o' }, src: 'app');
    _refresh();
    notifyListeners();
  }

  String get requestedMode => v2i.reqModeName(controller.reqMode);

  void toggleRxLog() {
    controller.command('r');
    notifyListeners();
  }

  bool get rxLogOn => controller.logRx;

  /// Writes an app line (not a firmware line) into the log, e.g. time spent in the background.
  void note(String text) => controller.log.add(v2i.LogLine(controller.millis(), '[APP ] $text', wall: DateTime.now()));

  // --- V3View (the four-lane cards) ----------------------------------------------------------

  @override
  V3State? get v3 => _v3;

  @override
  bool get isLive => running;

  @override
  bool get showingLastKnown => false;

  @override
  String? laneDisplay(String lane) {
    final l = v2i.laneIndex(lane);
    return l < 0 || !running ? null : controller.laneDisplay(l);
  }

  @override
  int? get remainingMs {
    final c = controller;
    final s = c.phase == v2i.Phase.green ? c.greenRemS() : c.phaseRemS();
    return (s * 1000).round();
  }

  @override
  int? get countdownS => (remainingMs! / 1000).ceil();

  @override
  int? get elapsedMs => controller.millis() - controller.phaseStart;

  @override
  double? get progress {
    final e = elapsedMs!, r = remainingMs!;
    return e + r <= 0 ? null : (e / (e + r)).clamp(0.0, 1.0);
  }

  @override
  String get countdownSource => 'Signal timing runs on this phone';
}
