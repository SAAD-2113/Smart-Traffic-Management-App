import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
    // the whole session: every log line, a snapshot per second, every vehicle decision
    recorder = v2i.SessionRecorder(controller, name: name);
  }

  late final v2i.SessionRecorder recorder;

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
        recorder.rtt(vid, ms);
      }
      ..onMember = (vid, online, emergency) {
        members[vid] = MemberInfo(online: online, emergency: emergency);
        notifyListeners();
      }
      ..onState = (state, reason) {
        linkState = state;
        linkReason = reason;
        notifyListeners();
      }
      // what the ESP32's own server does (used by the LAN transport)
      ..stateNow = (() => jsonEncode(controller.buildState()))
      ..onModeRequest = _modeRequest
      ..onWsText = _wsCommand
      ..onWsClient = ((id, on) => note('WebSocket client $id ${on ? 'connected' : 'disconnected'}'));
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

  /// One pass of loop(): injected vehicles read their ACKs and move, then the controller.
  void step() {
    final acks = List.of(_injectedAcks);
    _injectedAcks.clear();
    for (final (v, a) in acks) {
      v.onAck(a);
    }
    for (final v in injected) {
      v.tick();
    }
    controller.tick();
    recorder.tick();
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
    recorder.vehicleSample(vid);
    if (ack != null) {
      link.sendAck(vid, ack);
      acksOut++;
    }
  }

  // --- test injector: virtual vehicles that run the firmware's vehicle unit in this phone ----

  /// Injected vehicles (marked "inject" in the vehicle table). They talk to the controller
  /// directly; their ACK is read on their next pass, like over the air.
  final injected = <v2i.V2IVehicle>[];
  final _injectedAcks = <(v2i.V2IVehicle, String)>[];
  final _rnd = math.Random();

  Iterable<int> get injectedIds => injected.map((v) => v.vId);

  /// Adds a virtual vehicle. Presets keep their firmware ids (101..202); custom ones get 501..999.
  v2i.V2IVehicle inject(v2i.VehicleSpec spec) {
    if (injectedIds.contains(spec.id)) throw StateError('vehicle ${spec.id} is already injected');
    late final v2i.V2IVehicle v;
    v = v2i.V2IVehicle(
      spec: spec,
      clock: clock,
      hw: 'inject',
      geometry: controller.geometry,
      random: math.Random(_rnd.nextInt(1 << 31)),
      wallClock: DateTime.now,
      send: (packet) {
        if (!running) return;
        packetsIn++;
        final ack = controller.processPacket(packet);
        recorder.vehicleSample(spec.id);
        if (ack != null) _injectedAcks.add((v, ack));
      },
    );
    injected.add(v);
    note('test injector: vehicle ${spec.id} (${spec.type == v2i.VT_EMERGENCY ? 'emergency' : 'normal'}, arm '
        '${v2i.LANE_NAME[spec.arm]}, slot ${spec.slot}, ${spec.startDist.toStringAsFixed(0)} m, '
        '${spec.kmh.toStringAsFixed(0)} km/h, delay ${spec.delayS} s) added');
    notifyListeners();
    return v;
  }

  /// Switches an injected vehicle off: it stops sending and the controller drops it after 3 s.
  void removeInjected(int id) {
    final before = injected.length;
    injected.removeWhere((v) => v.vId == id);
    _injectedAcks.removeWhere((a) => a.$1.vId == id);
    if (injected.length != before) note('test injector: vehicle $id switched off');
    notifyListeners();
  }

  void removeAllInjected() {
    for (final id in injectedIds.toList()) {
      removeInjected(id);
    }
  }

  /// The injected vehicles as a scenario, for the Fixed vs Adaptive comparison.
  List<v2i.VehicleSpec> get injectedSpecs => [for (final v in injected) v.spec];

  /// GET /api/mode?m=… as in the firmware: set it, then reply with the modes.
  String _modeRequest(String m) {
    final c = controller;
    final ok = m.isNotEmpty && c.setReqModeByName(m, 'web /api/mode');
    _refresh();
    notifyListeners();
    return '{"ok":$ok,"requested_mode":"${v2i.reqModeName(c.reqMode)}","mode":"${v2i.modeName(c.effMode)}",'
        '"target_mode":"${v2i.modeName(c.targetMode())}"}';
  }

  /// A WebSocket text message as in the firmware: "auto" / "fixed" / "adaptive" or {"mode":"…"}.
  void _wsCommand(String text) {
    var msg = text.length > 95 ? text.substring(0, 95) : text;
    msg = msg.replaceFirst(RegExp(r'[ \n\r]+$'), '');
    if (controller.setReqModeByName(msg, 'WebSocket')) return;
    Object? cmd;
    try {
      cmd = jsonDecode(msg);
    } on FormatException {
      return; // the firmware ignores text that is neither a mode nor JSON
    }
    final m = cmd is Map && cmd['mode'] is String ? cmd['mode'] as String : '';
    if (!controller.setReqModeByName(m, 'WebSocket')) note('unknown WebSocket command: $msg');
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
