import 'dart:math' as math;

import 'cnum.dart';
import 'config.dart';
import 'geometry.dart';

/// V2IState / V2IReason from v2i_common.h, with the same names and reason strings.
enum V2IState {
  approaching('APPROACHING'),
  queued('QUEUED'),
  crossing('CROSSING'),
  ignored('IGNORED');

  const V2IState(this.label);
  final String label;
}

enum V2IReason {
  ok(''),
  outOfRange('out of range'),
  offArm('not on any arm'),
  headingAway('heading away / leaving'),
  inBoxNoLane('inside box, no previous lane');

  const V2IReason(this.label);
  final String label;
}

String stateName(V2IState s) => s.label;
String reasonName(V2IReason r) => r.label;

class V2IDecision {
  const V2IDecision({required this.lane, required this.st, required this.reason, required this.dist, required this.bearing});

  /// 0..3 or -1.
  final int lane;
  final V2IState st;

  /// Why IGNORED.
  final V2IReason reason;

  /// Metres from the centre (float).
  final double dist;

  /// Centre -> vehicle, degrees (float).
  final double bearing;
}

/// Thresholds of the lane decision. Defaults are the firmware's; tests may narrow the arm
/// half-angle to reach the "not on any arm" branch (see [v2iClassify]).
class ClassifyThresholds {
  const ClassifyThresholds({
    this.detectRadiusM = DETECT_RADIUS_M,
    this.junctionRM = JUNCTION_R_M,
    this.queueZoneM = QUEUE_ZONE_M,
    this.queueSpeedKmh = QUEUE_SPEED_KMH,
    this.armHalfAngleDeg = ARM_HALF_ANGLE_DEG,
    this.headingTolDeg = HEADING_TOL_DEG,
  });

  final double detectRadiusM;
  final double junctionRM;
  final double queueZoneM;
  final double queueSpeedKmh;
  final double armHalfAngleDeg;
  final double headingTolDeg;
}

/// 1:1 port of `v2iClassify()`: lane and state from position, speed and heading ONLY.
///   prevLane: lane decided from this vehicle's previous packet (-1 if none)
///   hdgValid: false if the sender gave no heading -> fall back to "getting closer"
///   prevDist: distance at the previous packet (only used when hdgValid == false)
///
/// Note (firmware behaviour, kept): the arms are 90 deg apart and the half-angle is 45 deg,
/// inclusive, so every bearing is within 45 deg of some arm and "not on any arm" cannot
/// happen with the firmware thresholds.
V2IDecision v2iClassify(
  double lat,
  double lon,
  double spdKmh,
  double hdgDeg,
  bool hdgValid,
  int prevLane,
  double prevDist, {
  Geometry geometry = const Geometry(),
  ClassifyThresholds th = const ClassifyThresholds(),
}) {
  final (x, y) = geometry.latlonToXY(lat, lon);
  final dist = f32(math.sqrt(x * x + y * y));
  final bearing = wrap360(f32(math.atan2(x, y) * 180.0 / math.pi));

  V2IDecision ignored(V2IReason why) => V2IDecision(lane: -1, st: V2IState.ignored, reason: why, dist: dist, bearing: bearing);

  if (dist > f32(th.detectRadiusM)) return ignored(V2IReason.outOfRange);

  if (dist < f32(th.junctionRM)) {
    // inside the junction box
    if (prevLane >= 0) {
      return V2IDecision(lane: prevLane, st: V2IState.crossing, reason: V2IReason.ok, dist: dist, bearing: bearing);
    }
    return ignored(V2IReason.inBoxNoLane);
  }

  var arm = -1;
  var best = 999.0;
  for (var i = 0; i < NUM_LANES; i++) {
    final d = angDiff(bearing, ARM_BEARING[i]);
    if (d <= f32(th.armHalfAngleDeg) && d < best) {
      best = d;
      arm = i;
    }
  }
  if (arm < 0) return ignored(V2IReason.offArm);

  final inbound = hdgValid
      ? angDiff(hdgDeg, wrap360(f32(ARM_BEARING[arm] + 180.0))) <= f32(th.headingTolDeg)
      : dist < f32(prevDist + 0.5);
  if (!inbound) return ignored(V2IReason.headingAway);

  final queued = f32(spdKmh) < f32(th.queueSpeedKmh) && dist <= f32(th.queueZoneM);
  return V2IDecision(
    lane: arm,
    st: queued ? V2IState.queued : V2IState.approaching,
    reason: V2IReason.ok,
    dist: dist,
    bearing: bearing,
  );
}
