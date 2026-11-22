/// State frames of firmware v3 (docs/firmware-v3): `{"v":2,"t":"state",...}` from the
/// intersection's WebSocket (port 81) every 500 ms, and from GET /api/state.
///
/// Every field is optional: a missing or unexpected value becomes null and the UI shows "—".
/// Parsing never throws. Units are the firmware's: seconds, metres, km/h.
library;

/// Lanes in firmware order (one lane per arm; one green at a time).
const v3Lanes = ['N', 'E', 'S', 'W'];

Map<String, dynamic> _map(Object? v) => v is Map ? v.map((k, val) => MapEntry('$k', val)) : const {};
String? _str(Object? v) => v is String ? v : (v is num || v is bool ? '$v' : null);
int? _int(Object? v) => v is int ? v : (v is num && v.isFinite ? v.round() : (v is String ? int.tryParse(v) : null));
double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : (v is String ? double.tryParse(v) : null);
bool? _bool(Object? v) => v is bool ? v : null;

/// "-" (the firmware's "none") becomes null.
String? _laneOrNull(Object? v) {
  final s = _str(v)?.trim().toUpperCase();
  return s == null || s.isEmpty || s == '-' ? null : s;
}

class V3Plan {
  const V3Plan({this.cycleS, this.y, this.lostS, this.k, this.satFlow, this.windowS});

  factory V3Plan.fromJson(Map<String, dynamic> j) => V3Plan(
    cycleS: _num(j['C']),
    y: _num(j['Y']),
    lostS: _num(j['L']),
    k: _num(j['K']),
    satFlow: _num(j['s']),
    windowS: _num(j['window_s']),
  );

  /// Webster cycle C0 of the preview plan (s).
  final double? cycleS;

  /// Sum of the flow ratios Y (capped at 0.90).
  final double? y;

  /// Lost time per cycle L (s).
  final double? lostS;

  /// Weight of approaching vehicles in Qw.
  final double? k;

  /// Saturation flow s (veh/h).
  final double? satFlow;

  /// Observation window (s).
  final double? windowS;
}

class V3Lane {
  const V3Lane({
    required this.lane,
    this.sig,
    this.remS,
    this.queued,
    this.approaching,
    this.crossing,
    this.emerg,
    this.qw,
    this.density,
    this.y,
    this.greenS,
  });

  factory V3Lane.fromJson(Map<String, dynamic> j) => V3Lane(
    lane: _laneOrNull(j['lane']) ?? '?',
    sig: _str(j['sig'])?.toUpperCase(),
    remS: _num(j['rem']),
    queued: _int(j['queued']),
    approaching: _int(j['approaching']) ?? _int(j['approach']),
    crossing: _int(j['crossing']),
    emerg: _int(j['emerg']),
    qw: _num(j['qw']),
    density: _str(j['density'])?.toUpperCase(),
    y: _num(j['y']),
    greenS: _num(j['g']),
  );

  final String lane;

  /// "G" | "Y" | "R".
  final String? sig;

  /// Seconds left in the current colour (red: estimated wait for green).
  final double? remS;
  final int? queued;
  final int? approaching;
  final int? crossing;
  final int? emerg;

  /// Weighted queue Qw = queued + K x approaching.
  final double? qw;

  /// "LOW" | "MEDIUM" | "HIGH".
  final String? density;

  /// Flow ratio of the preview plan.
  final double? y;

  /// Green of the current phase (if this lane is green) or of its next normal turn; 0 = skipped.
  final double? greenS;
}

class V3Vehicle {
  const V3Vehicle({
    this.id,
    this.ty,
    this.hw,
    this.lane,
    this.testLane,
    this.st,
    this.spdKmh,
    this.hdg,
    this.distM,
    this.lat,
    this.lon,
    this.rssi,
    this.pkts,
    this.lost,
    this.ageS,
  });

  factory V3Vehicle.fromJson(Map<String, dynamic> j) => V3Vehicle(
    id: _int(j['id']),
    ty: _int(j['ty']),
    hw: _str(j['hw']),
    lane: _laneOrNull(j['lane']),
    testLane: _laneOrNull(j['tl']),
    st: _str(j['st'])?.toUpperCase(),
    spdKmh: _num(j['spd']),
    hdg: _int(j['hdg']),
    distM: _num(j['dist']),
    lat: _num(j['lat']),
    lon: _num(j['lon']),
    rssi: _int(j['rssi']),
    pkts: _int(j['pkts']),
    lost: _int(j['lost']),
    ageS: _num(j['age_s']),
  );

  final int? id;

  /// 0 = normal, 1 = emergency.
  final int? ty;
  final String? hw;

  /// Lane decided by the intersection from the coordinates (null = none).
  final String? lane;

  /// Lane the test data says ("tl"), only used for the mismatch check.
  final String? testLane;

  /// "APPROACHING" | "QUEUED" | "CROSSING" | "IGNORED".
  final String? st;

  /// km/h, as the firmware sends it.
  final double? spdKmh;

  /// Degrees; -1 = no heading sent.
  final int? hdg;
  final double? distM;
  final double? lat;
  final double? lon;

  /// dBm, null when the vehicle did not send it.
  final int? rssi;
  final int? pkts;
  final int? lost;
  final double? ageS;

  bool get isEmergency => (ty ?? 0) != 0;

  /// The intersection's lane differs from the test data ([MISMATCH] on the controller).
  bool get mismatch => lane != null && testLane != null && lane != testLane;
}

class V3Timing {
  const V3Timing({this.phase, this.lane, this.targetGreenS, this.elapsedS, this.remainingS, this.nextPhase, this.priority});

  factory V3Timing.fromJson(Map<String, dynamic> j) => V3Timing(
    phase: _str(j['phase'])?.toUpperCase(),
    lane: _laneOrNull(j['lane']),
    targetGreenS: _num(j['target_green']),
    elapsedS: _num(j['elapsed']),
    remainingS: _num(j['remaining']),
    nextPhase: _str(j['next_phase'])?.toUpperCase(),
    priority: _bool(j['priority']),
  );

  final String? phase;
  final String? lane;
  final double? targetGreenS;
  final double? elapsedS;
  final double? remainingS;

  /// "YELLOW" | "ALL_RED" | "NEXT_GREEN".
  final String? nextPhase;
  final bool? priority;
}

class V3State {
  const V3State({
    this.version,
    this.mode,
    this.requestedMode,
    this.targetMode,
    this.modeReason,
    this.fallback,
    this.emergencyLane,
    this.priorityActive,
    this.uptimeS,
    this.cur,
    this.phase,
    this.rx,
    this.bad,
    this.controller,
    this.intersection,
    this.online,
    this.vehicleCount,
    this.congestion,
    this.queuedTotal,
    this.approachingTotal,
    this.plan = const V3Plan(),
    this.lanes = const [],
    this.vehicles = const [],
    this.timing = const V3Timing(),
  });

  factory V3State.fromJson(Map<String, dynamic> j) {
    final lanes = j['lanes'];
    final vehicles = j['vehicles'];
    return V3State(
      version: _int(j['v']),
      mode: _str(j['mode'])?.toLowerCase(),
      requestedMode: _str(j['requested_mode'])?.toLowerCase(),
      targetMode: _str(j['target_mode'])?.toLowerCase(),
      modeReason: _str(j['mode_reason']),
      fallback: _bool(j['fallback']),
      emergencyLane: _laneOrNull(j['emergency_lane']),
      priorityActive: _bool(j['priority_active']),
      uptimeS: _int(j['uptime_s']),
      cur: _laneOrNull(j['cur']),
      phase: _str(j['phase'])?.toUpperCase(),
      rx: _int(j['rx']),
      bad: _int(j['bad']),
      controller: _str(j['controller']),
      intersection: _str(j['intersection']),
      online: _bool(j['online']),
      vehicleCount: _int(j['vehicle_count']),
      congestion: _str(j['congestion'])?.toUpperCase(),
      queuedTotal: _int(j['queued_total']),
      approachingTotal: _int(j['approaching_total']),
      plan: V3Plan.fromJson(_map(j['plan'])),
      lanes: lanes is List
          ? [
              for (final l in lanes)
                if (l is Map) V3Lane.fromJson(_map(l)),
            ]
          : const [],
      vehicles: vehicles is List
          ? [
              for (final v in vehicles)
                if (v is Map) V3Vehicle.fromJson(_map(v)),
            ]
          : const [],
      timing: V3Timing.fromJson(_map(j['timing'])),
    );
  }

  final int? version;

  /// Effective mode: "fixed" | "adaptive".
  final String? mode;

  /// "auto" | "fixed" | "adaptive".
  final String? requestedMode;

  /// Mode the controller switches to at the next lane decision.
  final String? targetMode;
  final String? modeReason;

  /// AUTO is running fixed (no vehicle data).
  final bool? fallback;

  /// Lane of the emergency vehicle being served or waiting (null = none).
  final String? emergencyLane;
  final bool? priorityActive;
  final int? uptimeS;

  /// Lane of the current phase (null before the first green).
  final String? cur;

  /// "GREEN" | "YELLOW" | "ALL_RED".
  final String? phase;
  final int? rx;
  final int? bad;
  final String? controller;
  final String? intersection;
  final bool? online;
  final int? vehicleCount;

  /// "LOW" | "MEDIUM" | "HIGH".
  final String? congestion;
  final int? queuedTotal;
  final int? approachingTotal;
  final V3Plan plan;
  final List<V3Lane> lanes;
  final List<V3Vehicle> vehicles;
  final V3Timing timing;

  V3Lane? lane(String name) {
    for (final l in lanes) {
      if (l.lane == name) return l;
    }
    return null;
  }

  /// Lamp per lane for the junction view.
  Map<String, String?> get signals => {for (final n in v3Lanes) n: lane(n)?.sig};

  bool get isAdaptive => mode == 'adaptive';
  bool get isFixed => mode == 'fixed';
  bool get switchPending => targetMode != null && mode != null && targetMode != mode;

  /// AUTO fell back to fixed after vehicles were heard and then went silent (firmware text).
  bool get dataLost => fallback == true && (modeReason ?? '').startsWith('auto: no vehicle heard');

  /// The emergency vehicle nearest to the centre on [laneName], if any.
  V3Vehicle? emergencyOn(String? laneName) {
    V3Vehicle? best;
    for (final v in vehicles) {
      if (!v.isEmergency || v.lane != laneName) continue;
      if (best == null || (v.distM ?? 1e9) < (best.distM ?? 1e9)) best = v;
    }
    return best;
  }
}
