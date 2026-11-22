import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

import 'bench.dart';

/// Key order of buildState(), read from the firmware source itself.
class FirmwareKeys {
  FirmwareKeys(String ino) {
    final start = ino.indexOf('void buildState(JsonDocument &d)');
    final end = ino.indexOf('void broadcastAppState()');
    final body = ino.substring(start, end);
    final lanesAt = body.indexOf('JsonArray lanes');
    final vehAt = body.indexOf('JsonArray vs');
    final timingAt = body.indexOf('JsonObject timing');
    List<String> keys(String re, String s) => [for (final m in RegExp(re).allMatches(s)) m.group(1)!];
    top = keys(r'\bd\["(\w+)"\]', body);
    plan = keys(r'\bpl\["(\w+)"\]', body);
    lane = keys(r'\bo\["(\w+)"\]', body.substring(lanesAt, vehAt));
    vehicle = keys(r'\bo\["(\w+)"\]', body.substring(vehAt, timingAt)).toSet().toList(); // rssi appears twice (if/else)
    timing = keys(r'\btiming\["(\w+)"\]', body.substring(timingAt));
  }

  late final List<String> top, plan, lane, vehicle, timing;
}

void main() {
  final fw = FirmwareKeys(File('../../../docs/firmware-v3/intersection_esp32/intersection_esp32.ino').readAsStringSync());

  Map<String, Object?> busyState() {
    final b = Bench();
    b.addSender(StaticSender(id: 101, lat: 31.500111, lon: 74.299996, spd: 0, hdg: 181, tl: 'N', hw: 'ESP32-S3', from: 71000));
    final (lat, lon) = StaticSender.at(-60, 0);
    b.addSender(StaticSender(id: 201, ty: 1, lat: lat, lon: lon, spd: 30, hdg: 90, tl: 'W', from: 72000));
    b.runUntil(80000);
    return jsonDecode(jsonEncode(b.ic.buildState())) as Map<String, Object?>;
  }

  test('the firmware source parses into the expected sections', () {
    expect(fw.top.first, 'v');
    expect(fw.top.length, 25);
    expect(fw.plan, ['C', 'Y', 'L', 'K', 's', 'window_s']);
    expect(fw.lane.length, 12);
    expect(fw.vehicle.length, 15);
    expect(fw.timing.length, 7);
  });

  test('serialised text starts with {"v":2,"t":"state", (the app checks "v":2 first)', () {
    final b = Bench();
    expect(jsonEncode(b.ic.buildState()), startsWith('{"v":2,"t":"state",'));
  });

  test('same keys in the same order as the firmware, at every level', () {
    final s = busyState();
    expect(s.keys.toList(), fw.top);
    expect((s['plan'] as Map).keys.toList(), fw.plan);
    for (final l in s['lanes'] as List) {
      expect((l as Map).keys.toList(), fw.lane);
    }
    final vs = s['vehicles'] as List;
    expect(vs, hasLength(2));
    for (final v in vs) {
      expect((v as Map).keys.toList(), fw.vehicle);
    }
    expect((s['timing'] as Map).keys.toList(), fw.timing);
  });

  test('value types', () {
    final s = busyState();
    expect(s['v'], 2);
    for (final k in [
      't',
      'mode',
      'requested_mode',
      'target_mode',
      'mode_reason',
      'emergency_lane',
      'cur',
      'phase',
      'controller',
      'intersection',
      'congestion',
    ]) {
      expect(s[k], isA<String>(), reason: k);
    }
    for (final k in ['fallback', 'priority_active', 'online']) {
      expect(s[k], isA<bool>(), reason: k);
    }
    for (final k in ['uptime_s', 'rx', 'bad', 'vehicle_count', 'queued_total', 'approaching_total']) {
      expect(s[k], isA<int>(), reason: k);
    }
    for (final v in (s['plan'] as Map).values) {
      expect(v, isA<num>());
    }
    for (final l in s['lanes'] as List) {
      final m = l as Map;
      expect(m['lane'], isIn(LANE_NAME));
      expect(m['sig'], isIn(['G', 'Y', 'R']));
      expect(m['density'], isIn(['LOW', 'MEDIUM', 'HIGH']));
      for (final k in ['queued', 'approach', 'approaching', 'crossing', 'emerg']) {
        expect(m[k], isA<int>(), reason: k);
      }
      for (final k in ['rem', 'qw', 'y', 'g']) {
        expect(m[k], isA<num>(), reason: k);
      }
      expect(m['approach'], m['approaching'], reason: 'old key kept for the app');
    }
    final v = (s['vehicles'] as List).first as Map;
    expect(v['id'], 101);
    expect(v['ty'], 0);
    expect(v['hw'], 'ESP32-S3');
    expect((v['lane'], v['tl'], v['st']), ('N', 'N', 'QUEUED'));
    expect(v['hdg'], 181);
    expect(v['spd'], 0, reason: 'km/h');
    expect(v['dist'], 12.4);
    expect(v['lat'], 31.500111);
    expect(v['lon'], 74.299996);
    expect(v.containsKey('rssi'), isTrue);
    expect(v['rssi'], isNull, reason: 'no rssi sent -> null, like the firmware');
    final e = (s['vehicles'] as List)[1] as Map;
    expect((e['id'], e['ty'], e['lane'], e['st']), (201, 1, 'W', 'APPROACHING'));
    final t = s['timing'] as Map;
    expect(t['phase'], isIn(['GREEN', 'YELLOW', 'ALL_RED']));
    expect(t['next_phase'], isIn(['YELLOW', 'ALL_RED', 'NEXT_GREEN']));
    expect(t['priority'], isA<bool>());
  });

  test('numbers are written like ArduinoJson: integral floats without ".0"', () {
    final b = Bench();
    b.runUntil(3000);
    final text = jsonEncode(b.ic.buildState());
    expect(text, contains('"plan":{"C":30,"Y":0,"L":16,"K":0.5,"s":1800,"window_s":20}'));
    expect(
      text,
      contains(
        '{"lane":"N","sig":"G","rem":29,"queued":0,"approach":0,"approaching":0,"crossing":0,"emerg":0,'
        '"qw":0,"density":"LOW","y":0,"g":30}',
      ),
    );
    expect(
      text,
      contains(
        '"timing":{"phase":"GREEN","lane":"N","target_green":30,"elapsed":1,"remaining":29,'
        '"next_phase":"YELLOW","priority":false}',
      ),
    );
  });

  test('values at a known moment (README case 1, 1 s into N green)', () {
    final b = Bench();
    b.runUntil(3000);
    final s = b.ic.buildState();
    expect(s['mode'], 'fixed');
    expect(s['requested_mode'], 'auto');
    expect(s['target_mode'], 'fixed');
    expect(s['mode_reason'], 'auto: no vehicle connected -> fixed');
    expect(s['fallback'], true);
    expect(s['emergency_lane'], '-');
    expect(s['uptime_s'], 3);
    expect((s['cur'], s['phase']), ('N', 'GREEN'));
    expect([for (final l in s['lanes'] as List) (l as Map)['rem']], [29, 33, 67, 101]);
  });
}
