import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/hardware/monitor.dart';
import 'package:smart_traffic/hardware/settings.dart';

import 'fakes.dart';

void main() {
  late TestRig rig;
  late HardwareMonitor m;

  setUp(() {
    rig = TestRig();
    m = rig.monitor..start();
    rig.source.open();
  });

  tearDown(() => m.dispose());

  test('connected without data is STALE; a frame makes it ONLINE; a closed socket is OFFLINE', () {
    expect(m.status, LinkStatus.stale);
    rig.source.send(exampleFrame);
    expect(m.status, LinkStatus.online);
    rig.source.close();
    expect(m.status, LinkStatus.offline);
  });

  test('countdown comes from remaining_ms and counts down between frames', () {
    rig.source.send(exampleFrame); // 12980 ms left
    expect(m.countdownS, 13);
    rig.clock.advance(400);
    expect(m.countdownS, 13); // 12580
    rig.clock.advance(600);
    expect(m.countdownS, 12); // 11980
    expect(m.elapsedMs, 9020 + 1000);
    expect(m.progress, closeTo(10020 / 22000, 1e-6));
  });

  test('every frame re-anchors the countdown, also when the time jumps up', () {
    rig.source.send(exampleWith({'timing.remaining_ms': 5000}));
    expect(m.countdownS, 5);
    rig.clock.advance(500);
    rig.source.send(exampleWith({'timing.remaining_ms': 12000})); // green extended
    expect(m.countdownS, 12);
    rig.clock.advance(500);
    rig.source.send(exampleWith({'timing.remaining_ms': 3000})); // shortened
    expect(m.countdownS, 3);
  });

  test('STALE freezes the countdown at the moment data stopped', () {
    rig.source.send(exampleFrame); // 12980
    rig.clock.advance(1400);
    expect(m.status, LinkStatus.online);
    expect(m.countdownS, 12); // 11580
    rig.clock.advance(200); // 1.6 s without a frame
    expect(m.status, LinkStatus.stale);
    expect(m.showingLastKnown, isTrue);
    final frozen = m.remainingMs;
    expect(frozen, 12980 - 1500);
    rig.clock.advance(10000);
    expect(m.remainingMs, frozen, reason: 'never counts down without fresh frames');
    expect(m.countdownS, 12);
    // A new frame re-anchors and goes live again.
    rig.source.send(exampleWith({'timing.remaining_ms': 4000}));
    expect(m.status, LinkStatus.online);
    expect(m.countdownS, 4);
  });

  test('OFFLINE freezes at the moment the socket closed', () {
    rig.source.send(exampleFrame);
    rig.clock.advance(700);
    rig.source.close();
    expect(m.status, LinkStatus.offline);
    expect(m.remainingMs, 12980 - 700);
    rig.clock.advance(5000);
    expect(m.remainingMs, 12980 - 700);
    expect(m.state!.id, 'I01', reason: 'last known state stays visible');
  });

  test('switching from the simulator to the live source freezes the simulated state', () async {
    rig.monitor.dispose();
    rig = TestRig();
    m = rig.monitor;
    await m.settings.setSource(DataSource.simulator);
    m.start();
    rig.source.open();
    rig.source.send(exampleFrame);
    expect(m.showSimulated, isTrue);
    await m.setSource(DataSource.live);
    expect(m.status, LinkStatus.offline);
    expect(m.showingLastKnown, isTrue);
    expect(m.showSimulated, isTrue, reason: 'the frozen state came from the simulator');
    rig.source.open();
    rig.source.send(exampleFrame);
    expect(m.showSimulated, isFalse);
    expect(m.events.where((e) => e.title == 'Controller restarted'), isEmpty);
  });

  test('uptime going back adds "Controller restarted"', () {
    rig.source.send(exampleFrame);
    rig.source.send(exampleWith({'uptime_ms': 1200}));
    expect(m.events.first.title, 'Controller restarted');
    expect(m.events.first.fromApp, isTrue);
  });

  test('events are logged newest first, at most 20', () {
    for (var i = 0; i < 25; i++) {
      rig.source.send(eventFrame('phase_change', 'change $i', seq: i));
    }
    expect(m.events, hasLength(20));
    expect(m.events.first.detail, 'change 24');
    expect(m.events.first.title, 'Phase change');
  });

  test('ev_request shows a notice that can be dismissed', () {
    rig.source.send(eventFrame('ev_request', 'V05 E granted'));
    expect(m.notice!.request.vehicleId, 'V05');
    expect(m.notice!.request.approach, 'E');
    expect(m.notice!.request.result, 'granted');
    m.dismissNotice();
    expect(m.notice, isNull);
  });

  test('frames with another version are ignored with a warning', () {
    rig.source.send(exampleFrame);
    rig.source.send(exampleWith({'v': 3, 'id': 'OTHER'}));
    expect(m.unsupportedWarning, isTrue);
    expect(m.unsupportedVersion, 3);
    expect(m.state!.id, 'I01');
    rig.source.send(exampleFrame);
    expect(m.unsupportedWarning, isFalse);
  });

  test('a frame without timing shows no countdown and does not throw', () {
    rig.source.send(exampleWith({}, remove: ['timing']));
    expect(m.countdownS, isNull);
    expect(m.progress, isNull);
    expect(m.status, LinkStatus.online);
  });
}
