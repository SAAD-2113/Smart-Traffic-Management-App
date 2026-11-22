import 'dart:math' as math;

import 'package:v2i_core/v2i_core.dart';

/// A test bench: one intersection, vehicles talking to it with zero latency, a fake clock.
/// The clock starts at 1 s (the firmware's millis() is never 0 when packets arrive).
class Bench {
  Bench({String name = 'TEST'}) {
    ic = IntersectionController(clock: clock, intersectionName: name);
    ic.log.listen(all.add); // every line, not only the bounded log's last 5000
    ic.start();
  }

  final all = <LogLine>[];

  final clock = FakeClock(1000);
  late final IntersectionController ic;
  final vehicles = <V2IVehicle>[];
  final senders = <StaticSender>[];

  List<String> get lines => [for (final l in all) l.text];

  /// Lines with their time in ms since the bench started at 1000.
  List<(int, String)> get timed => [for (final l in all) (l.ms, l.text)];

  /// ACKs waiting for the vehicle's next loop() (the firmware reads them in receiveAck() at the
  /// start of the next pass, after [TX ]/[BASIS] were printed).
  final _pendingAcks = <(V2IVehicle, String)>[];

  V2IVehicle addVehicle(
    VehicleSpec spec, {
    VehicleSource source = VehicleSource.simulation,
    int seed = 1,
    String hw = 'bench',
    List<ReplayPoint> replay = REPLAY,
  }) {
    late final V2IVehicle v;
    v = V2IVehicle(
      spec: spec,
      clock: clock,
      hw: hw,
      source: source,
      replay: replay,
      random: math.Random(seed),
      send: (p) {
        final ack = ic.processPacket(p);
        if (ack != null) _pendingAcks.add((v, ack));
      },
    );
    vehicles.add(v);
    return v;
  }

  StaticSender addSender(StaticSender s) {
    senders.add(s);
    s.bench = this;
    return s;
  }

  /// Runs the loop for [ms] milliseconds in [step] ms increments.
  void run(int ms, {int step = 1, void Function()? each}) {
    for (var t = 0; t < ms; t += step) {
      clock.advance(step);
      final acks = List.of(_pendingAcks);
      _pendingAcks.clear();
      for (final (v, a) in acks) {
        v.onAck(a);
      }
      for (final s in senders) {
        s.tick();
      }
      for (final v in vehicles) {
        v.tick();
      }
      ic.tick();
      each?.call();
    }
  }

  /// Runs until absolute bench time [ms].
  void runUntil(int ms, {int step = 1, void Function()? each}) => run(ms - clock.ms, step: step, each: each);

  int? timeOf(Pattern p) {
    for (final (t, s) in timed) {
      if (s.contains(p)) return t;
    }
    return null;
  }

  List<String> sig() => [
    for (final l in lines)
      if (l.startsWith('[SIG ]')) l,
  ];
}

/// Sends a hand-made "pos" packet every 500 ms while active (like curl in a loop).
class StaticSender {
  StaticSender({
    required this.id,
    required this.lat,
    required this.lon,
    this.spd = 0,
    this.hdg,
    this.ty = 0,
    this.tl,
    this.hw = 'laptop',
    this.from = 0,
    this.until,
  });

  final int id;
  double lat, lon, spd;
  int? hdg;
  final int ty;
  final String? tl;
  final String hw;
  int from;
  int? until;
  int seq = 1;
  int _last = -1000000;
  late Bench bench;
  String? lastAck;

  /// Position from metres east / north of the default centre.
  static (double, double) at(double x, double y) => const Geometry().xyToLatLon(x, y);

  void move(double x, double y) {
    final (la, lo) = at(x, y);
    lat = la;
    lon = lo;
  }

  void tick() {
    final now = bench.clock.ms;
    if (now < from || (until != null && now >= until!)) return;
    if (now - _last < 500) return;
    _last = now;
    lastAck = bench.ic.processPacket(packet());
    seq++;
  }

  String packet() => PosPacket(id: id, ty: ty, lat: lat, lon: lon, spd: spd, hdg: hdg, seq: seq, hw: hw, tl: tl).encode();
}
