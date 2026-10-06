import 'dart:convert';

import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/hardware/link/clock.dart';
import 'package:smart_traffic/hardware/link/frame_source.dart';
import 'package:smart_traffic/hardware/monitor.dart';
import 'package:smart_traffic/hardware/platform/hardware_platform.dart';
import 'package:smart_traffic/hardware/settings.dart';

/// The example state frame from the hardware specification.
const exampleFrame = '''
{
  "v": 2, "type": "state", "id": "I01", "seq": 1532, "uptime_ms": 765000,
  "mode": "adaptive",
  "ctrl": "normal",
  "phase": "NS",
  "interval": "green",
  "signals": {"N": "G", "S": "G", "E": "R", "W": "R"},
  "timing": {"target_s": 22, "elapsed_ms": 9020, "remaining_ms": 12980,
             "next_phase": "EW", "reason": "NS demand 4 veh -> 22 s"},
  "plan": {"NS": {"g": 22, "y": 3, "ar": 2, "r": 19},
           "EW": {"g": 14, "y": 3, "ar": 2, "r": 27}},
  "approaches": {
    "N": {"queued": 3, "approaching": 1, "level": "high", "ev": false},
    "S": {"queued": 1, "approaching": 0, "level": "low", "ev": false},
    "E": {"queued": 1, "approaching": 0, "level": "low", "ev": false},
    "W": {"queued": 0, "approaching": 0, "level": "free", "ev": false}
  },
  "vehicles": [
    {"id": "V01", "type": "normal", "app": "N", "state": "queued", "dist_m": 12.4, "spd": 0.0, "eta_s": 0}
  ],
  "demand": {"NS": 4, "EW": 1},
  "total_vehicles": 6,
  "congestion": "high",
  "preempt": {"active": false, "approach": null, "vehicle_id": null, "status": "none"},
  "v2i": {"link": "ok", "active_vehicles": 6, "pkts_per_s": 6.0, "last_pkt_ms_ago": 180, "rejected": 0},
  "health": {"clients": 1, "heap": 182000, "fw": "1.0.0"}
}
''';

/// The example frame with some values replaced (dotted paths, e.g. "timing.remaining_ms").
String exampleWith(Map<String, Object?> changes, {List<String> remove = const []}) {
  final j = jsonDecode(exampleFrame) as Map<String, dynamic>;
  void apply(String path, Object? value, {bool delete = false}) {
    final parts = path.split('.');
    var node = j;
    for (final p in parts.take(parts.length - 1)) {
      node = node[p] as Map<String, dynamic>;
    }
    if (delete) {
      node.remove(parts.last);
    } else {
      node[parts.last] = value;
    }
  }

  changes.forEach(apply);
  for (final r in remove) {
    apply(r, null, delete: true);
  }
  return jsonEncode(j);
}

String eventFrame(String event, String detail, {int seq = 2000}) =>
    jsonEncode({'v': 2, 'type': 'event', 'seq': seq, 'uptime_ms': 765120, 'event': event, 'detail': detail});

/// A frame source driven by the test.
class FakeSource implements FrameSource {
  FakeSource({this.isSimulator = false});

  @override
  final bool isSimulator;

  @override
  void Function(String text)? onFrame;

  @override
  void Function(bool open)? onOpen;

  bool started = false;

  @override
  String get label => 'ws://test/';

  @override
  void start() => started = true;

  @override
  void stop() {
    started = false;
    onOpen?.call(false);
  }

  void open() => onOpen?.call(true);
  void close() => onOpen?.call(false);
  void send(String text) => onFrame?.call(text);
}

/// No native calls in tests.
class NoPlatform extends HardwarePlatform {
  const NoPlatform();

  @override
  Future<bool> bindToWifi() async => false;

  @override
  Future<void> releaseWifi() async {}

  @override
  Future<bool> isBoundToWifi() async => false;

  @override
  Future<void> keepScreenOn(bool on) async {}
}

/// A monitor with a fake clock and fake sources (one per data source; a new one on each restart).
class TestRig {
  TestRig({KeyValueStore? store, bool simulator = false}) : store = store ?? MemoryKeyValueStore() {
    monitor = HardwareMonitor(
      settings: HardwareSettings(this.store),
      clock: clock,
      platform: const NoPlatform(),
      createSource: (s) {
        final src = FakeSource(isSimulator: simulator || s.source == DataSource.simulator);
        sources.add(src);
        return src;
      },
      statusCheckInterval: const Duration(milliseconds: 100),
    );
  }

  final KeyValueStore store;
  final clock = FakeMonoClock(1000000);
  final sources = <FakeSource>[];
  late final HardwareMonitor monitor;

  FakeSource get source => sources.last;
}
