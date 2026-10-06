import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/hardware/model/frame.dart';
import 'package:smart_traffic/hardware/model/labels.dart';

import 'fakes.dart';

void main() {
  test('the example frame is read completely', () {
    final f = parseFrame(exampleFrame);
    expect(f, isA<StateFrame>());
    final s = (f as StateFrame).state;
    expect(s.id, 'I01');
    expect(s.seq, 1532);
    expect(s.uptimeMs, 765000);
    expect(s.mode, 'adaptive');
    expect(s.ctrl, 'normal');
    expect(s.phase, 'NS');
    expect(s.interval, 'green');
    expect(s.signals, {'N': 'G', 'S': 'G', 'E': 'R', 'W': 'R'});
    expect(s.timing.targetS, 22);
    expect(s.timing.elapsedMs, 9020);
    expect(s.timing.remainingMs, 12980);
    expect(s.timing.nextPhase, 'EW');
    expect(s.timing.reason, 'NS demand 4 veh -> 22 s');
    expect(s.plan['NS']!.green, 22);
    expect(s.plan['NS']!.red, 19);
    expect(s.plan['EW']!.green, 14);
    expect(s.plan['EW']!.red, 27);
    expect(s.approaches['N']!.queued, 3);
    expect(s.approaches['N']!.approaching, 1);
    expect(s.approaches['N']!.level, 'high');
    expect(s.approaches['W']!.level, 'free');
    expect(s.approaches['E']!.ev, false);
    expect(s.vehicles.single.id, 'V01');
    expect(s.vehicles.single.distM, 12.4);
    expect(s.vehicles.single.state, 'queued');
    expect(s.demand, {'NS': 4, 'EW': 1});
    expect(s.totalVehicles, 6);
    expect(s.congestion, 'high');
    expect(s.preemptActive, false);
    expect(s.preempt.status, 'none');
    expect(s.v2i.link, 'ok');
    expect(s.v2i.pktsPerS, 6.0);
    expect(s.v2i.lastPktMsAgo, 180);
    expect(s.health.heap, 182000);
    expect(s.health.firmware, '1.0.0');
    expect(s.v2iLost, false);
  });

  test('missing and wrongly typed fields become null instead of throwing', () {
    final s = (parseFrame('{"v":2,"type":"state","timing":"oops","signals":{"N":5},"plan":{"NS":"x"},'
                '"approaches":{"N":{"queued":"three"}},"vehicles":[1,{"id":7}],"total_vehicles":null}') as StateFrame)
        .state;
    expect(s.id, isNull);
    expect(s.mode, isNull);
    expect(s.timing.remainingMs, isNull);
    expect(s.signals['N'], '5');
    expect(s.signals['E'], isNull);
    expect(s.plan['NS']!.green, isNull);
    expect(s.approaches['N']!.queued, isNull);
    expect(s.vehicles.single.id, '7');
    expect(s.totalVehicles, isNull);
    expect(s.preemptActive, false);
  });

  test('unexpected values are kept as text', () {
    final s = (parseFrame(exampleWith({'mode': 'turbo', 'interval': 'blink'})) as StateFrame).state;
    expect(modeName(s.mode), 'TURBO');
    expect(intervalName(s.interval), 'BLINK');
  });

  test('only version 2 is accepted', () {
    expect(parseFrame(exampleWith({'v': 3})), isA<UnsupportedFrame>());
    expect((parseFrame(exampleWith({}, remove: ['v'])) as UnsupportedFrame).version, isNull);
    expect(parseFrame('not json'), isA<UnreadableFrame>());
    expect(parseFrame('[1,2]'), isA<UnreadableFrame>());
    expect(parseFrame('{"v":2,"type":"command"}'), isA<UnreadableFrame>());
    expect(parseFrame(eventFrame('ev_request', 'V05 E granted')), isA<EventFrame>());
  });

  test('ev_request details are split into vehicle, approach and result', () {
    final r = EvRequest.parse('V05 E granted');
    expect([r.vehicleId, r.approach, r.result], ['V05', 'E', 'granted']);
    final odd = EvRequest.parse('something else');
    expect(odd.vehicleId, isNull);
    expect(odd.detail, 'something else');
  });

  test('labels', () {
    expect(phaseLine('NS', 'green'), 'NORTH/SOUTH — GREEN');
    expect(phaseLine('EW', 'all_red'), 'EAST/WEST — ALL RED');
    expect(phaseLine('NONE', 'flash'), 'FLASHING');
    expect(phaseLine(null, null), '—');
    expect(uptime(765000), '12 min 45 s');
    expect(uptime(null), '—');
    expect(ago(300), '0.3 s ago');
  });
}
