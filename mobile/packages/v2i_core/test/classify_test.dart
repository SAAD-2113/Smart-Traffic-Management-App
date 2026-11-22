import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

const g = Geometry();

/// Classifies a point given in metres east (x) / north (y) of the default centre.
V2IDecision at(
  double x,
  double y, {
  double spd = 30,
  double hdg = -1,
  int prevLane = -1,
  double prevDist = 1e9,
  ClassifyThresholds? th,
}) {
  final (lat, lon) = g.xyToLatLon(x, y);
  return v2iClassify(lat, lon, spd, hdg, hdg >= 0, prevLane, f32(prevDist), th: th ?? const ClassifyThresholds());
}

void main() {
  group('README examples', () {
    test('curl point 31.499700, 74.300000, spd 0, hdg 0 -> S, QUEUED, 33 m south', () {
      final r = v2iClassify(31.499700, 74.300000, 0, 0, true, -1, f32(1e9));
      expect(LANE_NAME[r.lane], 'S');
      expect(r.st, V2IState.queued);
      expect(cfix(r.dist, 1), '33.4');
      expect(cfix(r.bearing, 0), '180');
    });

    test('mismatch point 31.500000, 74.300600, hdg 270 -> lane E (the tl field is not used)', () {
      final r = v2iClassify(31.500000, 74.300600, 0, 270, true, -1, f32(1e9));
      expect(LANE_NAME[r.lane], 'E');
      expect(cfix(r.bearing, 0), '90');
    });

    test('[RX] example 31.500111, 74.299996, spd 0, hdg 181 -> N QUEUED d=12.4 brg=358', () {
      final r = v2iClassify(31.500111, 74.299996, 0, 181, true, -1, f32(1e9));
      expect((LANE_NAME[r.lane], r.st, cfix(r.dist, 1), cfix(r.bearing, 0)), ('N', V2IState.queued, '12.4', '358'));
    });
  });

  group('each branch of v2iClassify', () {
    test('out of range beyond DETECT_RADIUS_M = 150 m', () {
      expect(at(0, 150.5, hdg: 180).reason, V2IReason.outOfRange);
      expect(at(0, 150.5, hdg: 180).st, V2IState.ignored);
      expect(at(0, 149.5, hdg: 180).st, V2IState.approaching);
    });

    test('inside the box (< 10 m): CROSSING on the previous lane, else ignored', () {
      final noPrev = at(0, 5, hdg: 180);
      expect((noPrev.lane, noPrev.st, noPrev.reason), (-1, V2IState.ignored, V2IReason.inBoxNoLane));
      expect(reasonName(noPrev.reason), 'inside box, no previous lane');
      final withPrev = at(-4, 0, hdg: 0, prevLane: 0); // heading ignored inside the box
      expect((withPrev.lane, withPrev.st), (0, V2IState.crossing));
      expect(at(0, 9.9, hdg: 180).st, V2IState.ignored);
      expect(at(0, 10.1, hdg: 180).st, isNot(V2IState.ignored));
    });

    test('heading must point to the centre within HEADING_TOL_DEG = 60 (inclusive)', () {
      expect(at(0, 50, hdg: 0).reason, V2IReason.headingAway); // north arm, driving north = leaving
      expect(reasonName(V2IReason.headingAway), 'heading away / leaving');
      expect(at(0, 50, hdg: 240).st, V2IState.approaching);
      expect(at(0, 50, hdg: 241).reason, V2IReason.headingAway);
      expect(at(0, 50, hdg: 120).st, V2IState.approaching);
      expect(at(0, 50, hdg: 119).reason, V2IReason.headingAway);
      expect(at(-50, 0, hdg: 30).st, V2IState.approaching, reason: 'W arm inbound = 90, 30 is 60 off');
    });

    test('QUEUED needs spd < 5 km/h AND dist <= 60 m, else APPROACHING', () {
      expect(at(0, 59, spd: 4.9, hdg: 180).st, V2IState.queued);
      expect(at(0, 59, spd: 5.0, hdg: 180).st, V2IState.approaching);
      expect(at(0, 61, spd: 0, hdg: 180).st, V2IState.approaching);
    });

    test('no heading (hdgValid = false): inbound if the distance shrank (+0.5 m tolerance)', () {
      expect(at(0, 50).st, V2IState.approaching, reason: 'first packet: prevDist = 1e9');
      expect(at(0, 50, prevDist: 50.4).st, V2IState.approaching);
      expect(at(0, 50.4, prevDist: 50).st, V2IState.approaching, reason: '50.4 < 50.0 + 0.5');
      expect(at(0, 50.6, prevDist: 50).reason, V2IReason.headingAway);
    });

    test('bearings wrap at 360: just west of north is still N', () {
      final r = at(-1, 50, hdg: 180);
      expect(r.lane, 0);
      expect(r.bearing, greaterThan(358));
    });

    test('"not on any arm" is unreachable with the firmware thresholds (45 deg inclusive, arms 90 deg apart)', () {
      var offArm = 0;
      for (var b10 = 0; b10 < 3600; b10++) {
        final rad = b10 / 10 * math.pi / 180;
        final r = at(50 * math.sin(rad), 50 * math.cos(rad), hdg: 0);
        if (r.reason == V2IReason.offArm) offArm++;
      }
      expect(offArm, 0);
    });

    test('... but the branch works when the half-angle is narrower (test-only threshold)', () {
      const narrow = ClassifyThresholds(armHalfAngleDeg: 40);
      final r = at(40, 40, hdg: 225, th: narrow); // bearing 45: 45 deg from N and from E
      expect((r.lane, r.st, r.reason), (-1, V2IState.ignored, V2IReason.offArm));
      expect(reasonName(r.reason), 'not on any arm');
    });
  });

  test('state and reason strings are the firmware strings', () {
    expect(V2IState.values.map(stateName), ['APPROACHING', 'QUEUED', 'CROSSING', 'IGNORED']);
    expect(V2IReason.values.map(reasonName), [
      '',
      'out of range',
      'not on any arm',
      'heading away / leaving',
      'inside box, no previous lane',
    ]);
  });

  test('the junction centre comes from the geometry (digital sessions use their own centre)', () {
    const lahore = Geometry(centerLat: 31.520370, centerLon: 74.358749);
    final (lat, lon) = lahore.xyToLatLon(0, -30);
    final r = v2iClassify(lat, lon, 0, 0, true, -1, f32(1e9), geometry: lahore);
    expect((LANE_NAME[r.lane], r.st, cfix(r.dist, 1)), ('S', V2IState.queued, '30.0'));
  });
}
