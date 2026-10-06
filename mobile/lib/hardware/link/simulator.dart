import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'clock.dart';
import 'frame_source.dart';

/// Development stand-in for the ESP32 controller. It produces frames in exactly the protocol
/// v2 format at the same rate (a state frame every 500 ms and immediately on any change).
///
/// Cycle: NS green -> NS yellow (3 s) -> all-red (2 s) -> EW green -> EW yellow (3 s) ->
/// all-red (2 s) -> repeat. Adaptive green = clamp(6 + 2 x demand, 10, 60) s, where demand
/// is the number of vehicles queued or approaching on the phase when its green starts. Fixed
/// mode uses a 20 s green. Vehicles arrive at random rates that change every few seconds,
/// queue on red and leave on green. About once a minute an emergency vehicle requests priority.
///
/// Everything it sends is simulated; the app marks it "SIMULATED DATA".
class HardwareSimulator {
  HardwareSimulator({required this.emit, Random? random, this.emergencies = true}) : _rnd = random ?? Random();

  /// Receives each frame as JSON text.
  final void Function(String json) emit;

  /// Set false in tests that check exact green durations (preemption shortens greens).
  final bool emergencies;
  final Random _rnd;

  static const tickMs = 100;
  static const stateEveryMs = 500;
  static const yellowMs = 3000;
  static const allRedMs = 2000;
  static const fixedGreenS = 20;
  static const minGreenBeforePreemptMs = 5000;
  static const intersectionId = 'SIM-I01';
  static const firmware = 'simulator';

  static int adaptiveGreenS(int demand) => (6 + 2 * demand).clamp(10, 60);

  int _now = 0;
  int _seq = 0;
  bool _started = false;

  String mode = 'adaptive';
  bool linkLost = false;

  String _phase = 'NS';
  String _interval = 'green';
  int _intervalStart = 0;
  int _intervalEnd = 0;
  String _reason = '';
  final _lastGreen = {'NS': fixedGreenS, 'EW': fixedGreenS};

  final _vehicles = <_SimVehicle>[];
  int _nextVehicle = 1;
  final _rates = {'N': 0.1, 'S': 0.1, 'E': 0.1, 'W': 0.1};
  int _nextRateChange = 0;
  final _nextDischarge = {'N': 0, 'S': 0, 'E': 0, 'W': 0};

  int _nextState = 0;
  int _nextEmergency = 30000;
  int _rejected = 0;
  int _lastVehicleSeen = 0;
  int _heap = 182000;

  // Emergency preemption.
  bool _preemptActive = false;
  String? _preemptApproach;
  String? _preemptVehicle;
  String _preemptStatus = 'none';
  int _preemptStatusUntil = 0;
  int _preemptSince = 0;

  int get nowMs => _now;
  String get phase => _phase;
  String get interval => _interval;

  /// Starts at uptime 0 with a "restart" event, a few vehicles and NS green.
  void start() {
    if (_started) return;
    _started = true;
    _changeRates();
    for (final a in ['N', 'S', 'E', 'W']) {
      final n = _rnd.nextInt(3);
      for (var i = 0; i < n; i++) {
        _spawn(a, dist: 20.0 + 15 * i + _rnd.nextDouble() * 10);
      }
    }
    _event('restart', 'simulator started');
    _startGreen('NS');
    _sendState();
  }

  /// Runs the simulation up to [targetMs] (simulated uptime) in 100 ms steps.
  void advanceTo(int targetMs) {
    if (!_started) start();
    while (_now + tickMs <= targetMs) {
      _now += tickMs;
      _step();
    }
  }

  /// Like the hardware's physical mode button. Simulator only: the app never commands hardware.
  void pressModeButton() {
    final from = mode;
    mode = mode == 'adaptive' ? 'fixed' : 'adaptive';
    _event('mode_change', '$from -> $mode');
    _sendState();
  }

  void setLinkLost(bool lost) {
    if (lost == linkLost) return;
    linkLost = lost;
    _event(lost ? 'v2i_lost' : 'v2i_restored', lost ? 'no vehicle packets' : 'vehicle packets received');
    _sendState();
  }

  /// Emergency request right now (otherwise about once a minute).
  void requestEmergencyNow() => _nextEmergency = _now;

  // --- simulation ----------------------------------------------------------------------

  void _step() {
    if (_now >= _nextRateChange) _changeRates();
    for (final a in _rates.keys) {
      if (_rnd.nextDouble() < _rates[a]! * tickMs / 1000) _spawn(a);
    }
    _moveVehicles();
    if (emergencies && !_preemptActive && _now >= _nextEmergency) _emergencyRequest();
    _preemptControl();
    if (_preemptStatus == 'rejected' && _now >= _preemptStatusUntil) _preemptStatus = 'none';

    if (_now >= _intervalEnd) {
      switch (_interval) {
        case 'green':
          _setInterval('yellow', yellowMs, 'Yellow ${yellowMs ~/ 1000} s');
        case 'yellow':
          _setInterval('all_red', allRedMs, 'All-red clearance ${allRedMs ~/ 1000} s');
        default:
          _startGreen(_nextPhase);
      }
      _sendState();
    } else if (_now >= _nextState) {
      _sendState();
    }
  }

  /// Phases always alternate, also during preemption: a conflicting green is cut short
  /// (after its minimum green) instead of being skipped.
  String get _nextPhase => _phase == 'NS' ? 'EW' : 'NS';

  static String _phaseOf(String approach) => approach == 'N' || approach == 'S' ? 'NS' : 'EW';
  static List<String> _approachesOf(String phase) => phase == 'NS' ? const ['N', 'S'] : const ['E', 'W'];

  void _setInterval(String interval, int durationMs, String reason) {
    _interval = interval;
    _intervalStart = _now;
    _intervalEnd = _now + durationMs;
    _reason = reason;
  }

  void _startGreen(String phase) {
    _phase = phase;
    final int green;
    if (linkLost) {
      green = fixedGreenS;
      _reason = 'V2I link lost: fixed plan $green s';
    } else if (mode == 'fixed') {
      green = fixedGreenS;
      _reason = 'Fixed plan $green s';
    } else {
      final demand = _demand(phase);
      green = adaptiveGreenS(demand);
      _reason = '$phase demand $demand veh -> $green s';
    }
    _lastGreen[phase] = green;
    _setInterval('green', green * 1000, _reason);
    _event('phase_change', '$phase green $green s');
  }

  void _changeRates() {
    for (final a in _rates.keys) {
      _rates[a] = _rnd.nextDouble() * 0.35;
    }
    _nextRateChange = _now + 3000 + _rnd.nextInt(3000);
  }

  _SimVehicle _spawn(String approach, {double? dist, bool emergency = false}) {
    final v = _SimVehicle(
      id: 'V${(_nextVehicle++).toString().padLeft(2, '0')}',
      type: emergency ? 'emergency' : 'normal',
      approach: approach,
      dist: dist ?? 60 + _rnd.nextDouble() * 10,
      speed: emergency ? 10.0 : 4 + _rnd.nextDouble() * 4,
    );
    _vehicles.add(v);
    return v;
  }

  String _lamp(String approach) {
    if (!_approachesOf(_phase).contains(approach)) return 'R';
    return switch (_interval) { 'green' => 'G', 'yellow' => 'Y', _ => 'R' };
  }

  void _moveVehicles() {
    final dt = tickMs / 1000;
    for (final a in ['N', 'S', 'E', 'W']) {
      final lamp = _lamp(a);
      final onApproach = _vehicles.where((v) => v.approach == a && v.state != 'departed').toList()
        ..sort((x, y) => x.dist.compareTo(y.dist));
      var queued = onApproach.where((v) => v.state == 'queued').length;
      // Queued vehicles leave one by one on green (2 s headway).
      if (lamp == 'G' && queued > 0 && _now >= _nextDischarge[a]!) {
        final front = onApproach.firstWhere((v) => v.state == 'queued');
        _depart(front);
        for (final v in onApproach.where((v) => v.state == 'queued')) {
          v.dist = max(2.0, v.dist - 5);
        }
        queued--;
        _nextDischarge[a] = _now + 2000;
      }
      for (final v in onApproach.where((v) => v.state == 'approaching')) {
        final next = v.dist - v.speed * dt;
        final mustStop = lamp == 'R' || (lamp == 'Y' && v.dist > 8);
        if (!mustStop && queued == 0) {
          if (next <= 0) {
            _depart(v);
          } else {
            v.dist = next;
          }
        } else {
          final stopAt = 2.0 + 5.0 * queued;
          if (next <= stopAt) {
            v
              ..dist = stopAt
              ..speed = 0
              ..state = 'queued';
            queued++;
          } else {
            v.dist = next;
          }
        }
      }
      if (lamp == 'G' && queued == 0) _nextDischarge[a] = max(_nextDischarge[a]!, _now);
    }
    _vehicles.removeWhere((v) => v.state == 'departed' && _now - v.departedAt > 1000);
    if (_vehicles.any((v) => v.state != 'departed')) _lastVehicleSeen = _now;
  }

  void _depart(_SimVehicle v) {
    v
      ..state = 'departed'
      ..dist = 0
      ..speed = max(v.speed, 5)
      ..departedAt = _now;
  }

  void _emergencyRequest() {
    _nextEmergency = _now + 55000 + _rnd.nextInt(10000);
    if (linkLost) return; // no V2I, no request
    final approach = const ['N', 'S', 'E', 'W'][_rnd.nextInt(4)];
    final ev = _spawn(approach, dist: 80, emergency: true);
    final granted = _rnd.nextDouble() < 0.8;
    _event('ev_request', '${ev.id} $approach ${granted ? 'granted' : 'rejected'}');
    if (granted) {
      _preemptActive = true;
      _preemptApproach = approach;
      _preemptVehicle = ev.id;
      _preemptStatus = 'granted';
      _preemptSince = _now;
      _event('preempt_start', '${ev.id} $approach');
    } else {
      _preemptStatus = 'rejected';
      _preemptStatusUntil = _now + 5000;
    }
    _sendState();
  }

  void _preemptControl() {
    if (!_preemptActive) return;
    final ev = _vehicles.where((v) => v.id == _preemptVehicle).firstOrNull;
    final gone = ev == null || ev.state == 'departed';
    if (gone || _now - _preemptSince > 40000) {
      _event('preempt_end', '$_preemptVehicle ${gone ? 'cleared' : 'expired'}');
      _preemptActive = false;
      _preemptStatus = gone ? 'none' : 'expired';
      _preemptStatusUntil = _now + 5000;
      _preemptApproach = null;
      _preemptVehicle = null;
      _sendState();
      return;
    }
    final target = _phaseOf(_preemptApproach!);
    if (_interval != 'green') return;
    if (_phase == target) {
      // Hold the green for the emergency vehicle (the countdown jumps up).
      if (_intervalEnd - _now < 2000) {
        _intervalEnd = _now + 3000;
        _reason = 'Emergency preemption: green held for $_preemptVehicle';
        _sendState();
      }
    } else if (_now - _intervalStart >= minGreenBeforePreemptMs) {
      // End the conflicting green early, through yellow and all-red as usual.
      _setInterval('yellow', yellowMs, 'Emergency preemption: changing to $target');
      _sendState();
    }
  }

  int _demand(String phase) => _approachesOf(phase)
      .map((a) => _vehicles.where((v) => v.approach == a && v.state != 'departed').length)
      .fold(0, (x, y) => x + y);

  static String _level(int n) => n == 0 ? 'free' : (n <= 2 ? 'low' : (n <= 4 ? 'medium' : 'high'));

  // --- frames --------------------------------------------------------------------------

  void _event(String event, String detail) {
    emit(jsonEncode({'v': 2, 'type': 'event', 'seq': ++_seq, 'uptime_ms': _now, 'event': event, 'detail': detail}));
  }

  void _sendState() {
    _nextState = _now + stateEveryMs;
    emit(jsonEncode(stateJson()));
  }

  Map<String, Object?> stateJson() {
    final visible = linkLost ? const <_SimVehicle>[] : _vehicles;
    int count(String a, String state) => visible.where((v) => v.approach == a && v.state == state).length;
    final approaches = <String, Object?>{};
    var worst = 0;
    for (final a in ['N', 'S', 'E', 'W']) {
      final q = count(a, 'queued');
      final ap = count(a, 'approaching');
      worst = max(worst, q + ap);
      approaches[a] = {
        'queued': q,
        'approaching': ap,
        'level': _level(q + ap),
        'ev': visible.any((v) => v.approach == a && v.isEmergency && v.state != 'departed'),
      };
    }
    final active = visible.where((v) => v.state != 'departed').length;
    if (!linkLost && _rnd.nextDouble() < 0.01) _rejected++;
    _heap = (_heap + _rnd.nextInt(2001) - 1000).clamp(170000, 190000);
    final g = {'NS': mode == 'fixed' ? fixedGreenS : _lastGreen['NS']!, 'EW': mode == 'fixed' ? fixedGreenS : _lastGreen['EW']!};
    const y = yellowMs ~/ 1000, ar = allRedMs ~/ 1000;
    int demandSeen(String phase) => linkLost ? 0 : _demand(phase);
    return {
      'v': 2,
      'type': 'state',
      'id': intersectionId,
      'seq': ++_seq,
      'uptime_ms': _now,
      'mode': mode,
      'ctrl': _preemptActive ? 'preempt' : (linkLost ? 'fallback' : 'normal'),
      'phase': _phase,
      'interval': _interval,
      'signals': {for (final a in ['N', 'S', 'E', 'W']) a: _lamp(a)},
      'timing': {
        'target_s': ((_intervalEnd - _intervalStart) / 1000).round(),
        'elapsed_ms': _now - _intervalStart,
        'remaining_ms': max(0, _intervalEnd - _now),
        'next_phase': _nextPhase,
        'reason': _reason,
      },
      'plan': {
        'NS': {'g': g['NS'], 'y': y, 'ar': ar, 'r': g['EW']! + y + ar},
        'EW': {'g': g['EW'], 'y': y, 'ar': ar, 'r': g['NS']! + y + ar},
      },
      'approaches': approaches,
      'vehicles': [
        for (final v in visible)
          {
            'id': v.id,
            'type': v.type,
            'app': v.approach,
            'state': v.state,
            'dist_m': double.parse(v.dist.toStringAsFixed(1)),
            'spd': double.parse(v.speed.toStringAsFixed(1)),
            'eta_s': v.state == 'approaching' && v.speed > 0 ? double.parse((v.dist / v.speed).toStringAsFixed(1)) : 0,
          },
      ],
      'demand': {'NS': demandSeen('NS'), 'EW': demandSeen('EW')},
      'total_vehicles': active,
      'congestion': _level(worst),
      'preempt': {
        'active': _preemptActive,
        'approach': _preemptApproach,
        'vehicle_id': _preemptVehicle,
        'status': _preemptActive || _now < _preemptStatusUntil ? _preemptStatus : 'none',
      },
      'v2i': {
        'link': linkLost ? 'lost' : 'ok',
        'active_vehicles': active,
        'pkts_per_s': double.parse((active * 2.0).toStringAsFixed(1)),
        'last_pkt_ms_ago': active > 0 ? 20 + _rnd.nextInt(280) : _now - _lastVehicleSeen,
        'rejected': _rejected,
      },
      'health': {'clients': 1, 'heap': _heap, 'fw': firmware},
    };
  }
}

class _SimVehicle {
  _SimVehicle({required this.id, required this.type, required this.approach, required this.dist, required this.speed});

  final String id;
  final String type;
  final String approach;
  double dist;
  double speed;
  String state = 'approaching';
  int departedAt = 0;

  bool get isEmergency => type == 'emergency';
}

/// Runs the simulator in real time as a frame source.
class SimulatorSource implements FrameSource {
  SimulatorSource({MonoClock? clock, Random? random}) : _clock = clock ?? SystemMonoClock() {
    sim = HardwareSimulator(emit: (text) => onFrame?.call(text), random: random);
  }

  final MonoClock _clock;
  late final HardwareSimulator sim;
  Timer? _timer;
  int _startedAt = 0;

  @override
  void Function(String text)? onFrame;

  @override
  void Function(bool open)? onOpen;

  @override
  bool get isSimulator => true;

  @override
  String get label => 'Simulator';

  @override
  void start() {
    _startedAt = _clock.nowMs();
    onOpen?.call(true);
    sim.start();
    _timer = Timer.periodic(const Duration(milliseconds: HardwareSimulator.tickMs), (_) {
      sim.advanceTo(_clock.nowMs() - _startedAt);
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    onOpen?.call(false);
  }
}
