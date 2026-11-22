import 'dart:async';

import 'links.dart';

/// In-process transport: vehicles and the intersection in the same app (tests, and the test
/// injector on the intersection phone). Messages are delivered asynchronously, like a network,
/// so a vehicle reads its ACK on a later pass of its loop, as on the ESP32.
class LoopbackHub {
  LoopbackHub({this.latency = Duration.zero});

  /// One-way delay added to every message (zero = next microtask).
  final Duration latency;
  LoopbackIntersectionLink? _intersection;
  final _vehicles = <int, LoopbackVehicleLink>{};

  LoopbackIntersectionLink intersection() => _intersection = LoopbackIntersectionLink._(this);

  LoopbackVehicleLink vehicle(int vid, {bool emergency = false}) => LoopbackVehicleLink._(this, vid, emergency);

  void _deliver(void Function() f) {
    if (latency == Duration.zero) {
      scheduleMicrotask(f);
    } else {
      Timer(latency, f);
    }
  }
}

class LoopbackIntersectionLink extends IntersectionLink {
  LoopbackIntersectionLink._(this._hub);
  final LoopbackHub _hub;
  bool _on = false;

  @override
  String get label => 'In-app (loopback)';

  @override
  void start() {
    _on = true;
    onState?.call(LinkState.online, null);
    for (final v in _hub._vehicles.values) {
      onMember?.call(v.vid, true, v.emergency);
      v.onIntersection?.call(true);
    }
  }

  @override
  void stop() {
    _on = false;
    for (final v in _hub._vehicles.values) {
      v.onIntersection?.call(false);
    }
    onState?.call(LinkState.closed, 'stopped');
  }

  @override
  void sendAck(int vid, String raw) {
    final v = _hub._vehicles[vid];
    if (v != null && _on) _hub._deliver(() => v.onAck?.call(raw));
  }

  @override
  void sendState(String raw) {}
}

class LoopbackVehicleLink extends VehicleLink {
  LoopbackVehicleLink._(this._hub, this.vid, this.emergency);
  final LoopbackHub _hub;
  final int vid;
  final bool emergency;

  @override
  String get label => 'In-app (loopback)';

  @override
  void start() {
    _hub._vehicles[vid] = this;
    onState?.call(LinkState.online, null);
    final i = _hub._intersection;
    onIntersection?.call(i != null && i._on);
    if (i != null && i._on) i.onMember?.call(vid, true, emergency);
  }

  @override
  void stop() {
    if (_hub._vehicles[vid] == this) _hub._vehicles.remove(vid);
    final i = _hub._intersection;
    if (i != null && i._on) i.onMember?.call(vid, false, emergency);
    onState?.call(LinkState.closed, 'stopped');
  }

  @override
  void send(String raw) {
    final i = _hub._intersection;
    if (i != null && i._on) _hub._deliver(() => i.onPacket?.call(vid, raw));
  }

  @override
  void sendRtt(int ms) {
    final i = _hub._intersection;
    if (i != null && i._on) _hub._deliver(() => i.onRtt?.call(vid, ms));
  }
}
