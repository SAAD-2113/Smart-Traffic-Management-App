import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:v2i_core/v2i_core.dart' as v2i;

import 'frame_source.dart';

/// Hardware-mode simulator: the firmware v3 twin from v2i_core (same controller code, same
/// state JSON) with the six firmware vehicle presets in motion simulation. It emits the
/// controller's state every 500 ms, like the ESP32's WebSocket. Everything it sends is
/// simulated; the app marks it "SIMULATED DATA".
///
/// Run order as in the firmware README: the intersection starts, the vehicles are powered a
/// few seconds later (preset 5 and 6 then wait 30 s / 70 s out of range before driving in).
class TwinSource implements FrameSource {
  TwinSource({v2i.MonoClock? clock, this.tickMs = 10, this.vehiclesAfterMs = 5000, Random? random, this.useTimer = true})
    : _clock = clock ?? v2i.StopwatchClock(),
      _rnd = random ?? Random();

  final v2i.MonoClock _clock;
  final Random _rnd;

  /// Loop period of the twin (the firmware's loop() runs about every 1 ms; 10 ms is enough for
  /// 100 ms density checks and 500 ms beacons).
  final int tickMs;
  final int vehiclesAfterMs;

  /// False in tests: they call [step] themselves.
  final bool useTimer;

  late v2i.IntersectionController controller;
  final vehicles = <v2i.V2IVehicle>[];
  final _oneShot = <v2i.V2IVehicle>{};
  final _pendingAcks = <(v2i.V2IVehicle, String)>[];
  Timer? _timer;
  int _powerAt = 0;
  bool _powered = false;
  bool _vehiclesOn = true;
  int _nextEmergencyId = 203;
  int _emergencyArm = 0;

  @override
  void Function(String text)? onFrame;

  @override
  void Function(bool open)? onOpen;

  @override
  bool get isSimulator => true;

  @override
  String get label => 'Simulator (firmware v3 twin)';

  /// Vehicles are powered (sending). Off = README case 4: they are removed after 3 s.
  bool get vehiclesOn => _vehiclesOn;

  /// The requested mode of the simulated controller ("auto" / "fixed" / "adaptive").
  String get requestedMode => v2i.reqModeName(controller.reqMode);

  @override
  void start() {
    controller = v2i.IntersectionController(
      clock: _clock,
      intersectionName: 'TWIN-RSU',
      controllerName: 'Firmware v3 twin (simulated)',
    );
    controller.onBroadcast = (state) => onFrame?.call(jsonEncode(state));
    onOpen?.call(true);
    controller.start();
    _powerAt = _clock.nowMs() + vehiclesAfterMs;
    if (useTimer) _timer = Timer.periodic(Duration(milliseconds: tickMs), (_) => step());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    onOpen?.call(false);
  }

  /// One pass of the loop: ACKs from the last pass, vehicles, intersection.
  void step() {
    if (!_powered && _vehiclesOn && _clock.nowMs() >= _powerAt) _powerVehicles();
    final acks = List.of(_pendingAcks);
    _pendingAcks.clear();
    for (final (v, a) in acks) {
      v.onAck(a);
    }
    for (final v in List.of(vehicles)) {
      v.tick();
      if (_oneShot.contains(v) && v.tripDone) {
        vehicles.remove(v); // switched off after its trip; the controller drops it after 3 s
        _oneShot.remove(v);
      }
    }
    controller.tick();
  }

  v2i.V2IVehicle _vehicle(v2i.VehicleSpec spec, String hw) {
    late final v2i.V2IVehicle v;
    v = v2i.V2IVehicle(
      spec: spec,
      clock: _clock,
      hw: hw,
      random: Random(_rnd.nextInt(1 << 31)),
      send: (packet) {
        final ack = controller.processPacket(packet);
        if (ack != null) _pendingAcks.add((v, ack)); // read in the vehicle's next loop
      },
    );
    return v;
  }

  void _powerVehicles() {
    _powered = true;
    for (var i = 0; i < v2i.PRESETS.length; i++) {
      vehicles.add(_vehicle(v2i.PRESETS[i], 'twin-${i + 1}'));
    }
  }

  /// Power all vehicles off (they stop sending) or on again (they restart like after a reset).
  void setVehiclesOn(bool on) {
    if (on == _vehiclesOn) return;
    _vehiclesOn = on;
    vehicles.clear();
    _oneShot.clear();
    _pendingAcks.clear();
    _powered = false;
    _powerAt = _clock.nowMs();
  }

  /// A simulated Serial command ('f', 'a', 'o') on the twin controller.
  void command(String c) => controller.command(c, src: 'simulator');

  /// An extra emergency vehicle that drives in now (140 m out, 50 km/h) on the next arm.
  void emergencyNow() {
    final arm = const [3, 2, 0, 1][_emergencyArm++ % 4];
    final spec = v2i.VehicleSpec(
      id: _nextEmergencyId++,
      type: v2i.VT_EMERGENCY,
      arm: arm,
      slot: 0,
      startDist: 140,
      kmh: 50,
      delayS: 0,
    );
    final v = _vehicle(spec, 'twin-EV');
    vehicles.add(v);
    _oneShot.add(v);
  }
}
