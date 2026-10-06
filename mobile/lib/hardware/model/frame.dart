import 'dart:convert';

/// Frames sent by the ESP32 intersection controller (protocol version 2), JSON text frames.
///
/// Every field is optional on purpose: a missing or unexpected value becomes null and the UI
/// shows "—". Parsing never throws.

const supportedVersion = 2;

/// Approaches in display order, and the phase each belongs to.
const approaches = ['N', 'S', 'E', 'W'];
const phases = ['NS', 'EW'];

sealed class ParsedFrame {
  const ParsedFrame();
}

class StateFrame extends ParsedFrame {
  const StateFrame(this.state);
  final HwState state;
}

class EventFrame extends ParsedFrame {
  const EventFrame(this.event);
  final HwEvent event;
}

/// A frame with a protocol version this app does not understand ("v" is not 2).
class UnsupportedFrame extends ParsedFrame {
  const UnsupportedFrame(this.version);
  final Object? version;
}

/// Not JSON, not an object, or an unknown "type".
class UnreadableFrame extends ParsedFrame {
  const UnreadableFrame(this.reason);
  final String reason;
}

ParsedFrame parseFrame(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const UnreadableFrame('not JSON');
  }
  if (decoded is! Map) return const UnreadableFrame('not a JSON object');
  final j = decoded.map((k, v) => MapEntry('$k', v));
  final v = j['v'];
  if (_int(v) != supportedVersion) return UnsupportedFrame(v);
  return switch (j['type']) {
    'state' => StateFrame(HwState.fromJson(j)),
    'event' => EventFrame(HwEvent.fromJson(j)),
    final other => UnreadableFrame('unknown type ${other ?? '(missing)'}'),
  };
}

// --- tolerant readers --------------------------------------------------------------------

Map<String, dynamic> _map(Object? v) => v is Map ? v.map((k, val) => MapEntry('$k', val)) : const {};
String? _str(Object? v) => v is String ? v : (v is num || v is bool ? '$v' : null);
int? _int(Object? v) => v is int ? v : (v is num && v.isFinite ? v.round() : (v is String ? int.tryParse(v) : null));
double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : (v is String ? double.tryParse(v) : null);
bool? _bool(Object? v) => v is bool ? v : null;

/// Lower-case enum value ("adaptive", "green" …) or null.
String? _lower(Object? v) => _str(v)?.trim().toLowerCase();

// --- state frame -------------------------------------------------------------------------

class HwTiming {
  const HwTiming({this.targetS, this.elapsedMs, this.remainingMs, this.nextPhase, this.reason});

  factory HwTiming.fromJson(Map<String, dynamic> j) => HwTiming(
        targetS: _num(j['target_s']),
        elapsedMs: _int(j['elapsed_ms']),
        remainingMs: _int(j['remaining_ms']),
        nextPhase: _str(j['next_phase'])?.toUpperCase(),
        reason: _str(j['reason']),
      );

  final double? targetS;
  final int? elapsedMs;
  final int? remainingMs;
  final String? nextPhase;
  final String? reason;
}

class HwPhasePlan {
  const HwPhasePlan({this.green, this.yellow, this.allRed, this.red});

  factory HwPhasePlan.fromJson(Map<String, dynamic> j) =>
      HwPhasePlan(green: _num(j['g']), yellow: _num(j['y']), allRed: _num(j['ar']), red: _num(j['r']));

  final double? green;
  final double? yellow;
  final double? allRed;
  final double? red;
}

class HwApproach {
  const HwApproach({this.queued, this.approaching, this.level, this.ev});

  factory HwApproach.fromJson(Map<String, dynamic> j) => HwApproach(
        queued: _int(j['queued']),
        approaching: _int(j['approaching']),
        level: _lower(j['level']),
        ev: _bool(j['ev']),
      );

  final int? queued;
  final int? approaching;
  final String? level;
  final bool? ev;
}

class HwVehicle {
  const HwVehicle({this.id, this.type, this.approach, this.state, this.distM, this.speed, this.etaS});

  factory HwVehicle.fromJson(Map<String, dynamic> j) => HwVehicle(
        id: _str(j['id']),
        type: _lower(j['type']),
        approach: _str(j['app'])?.toUpperCase(),
        state: _lower(j['state']),
        distM: _num(j['dist_m']),
        speed: _num(j['spd']),
        etaS: _num(j['eta_s']),
      );

  final String? id;
  final String? type;
  final String? approach;
  final String? state;
  final double? distM;

  /// As sent in "spd". Taken to be metres per second (SI, like the rest of the system); the UI
  /// shows km/h. Change [speedUnitToKmh] if the firmware sends km/h.
  final double? speed;
  final double? etaS;

  bool get isEmergency => type == 'emergency' || type == 'ev' || type == 'ambulance';
}

/// Multiplier from the "spd" unit to km/h (3.6 for m/s).
const speedUnitToKmh = 3.6;

class HwPreempt {
  const HwPreempt({this.active, this.approach, this.vehicleId, this.status});

  factory HwPreempt.fromJson(Map<String, dynamic> j) => HwPreempt(
        active: _bool(j['active']),
        approach: _str(j['approach'])?.toUpperCase(),
        vehicleId: _str(j['vehicle_id']),
        status: _lower(j['status']),
      );

  final bool? active;
  final String? approach;
  final String? vehicleId;
  final String? status;
}

class HwV2i {
  const HwV2i({this.link, this.activeVehicles, this.pktsPerS, this.lastPktMsAgo, this.rejected});

  factory HwV2i.fromJson(Map<String, dynamic> j) => HwV2i(
        link: _lower(j['link']),
        activeVehicles: _int(j['active_vehicles']),
        pktsPerS: _num(j['pkts_per_s']),
        lastPktMsAgo: _int(j['last_pkt_ms_ago']),
        rejected: _int(j['rejected']),
      );

  final String? link;
  final int? activeVehicles;
  final double? pktsPerS;
  final int? lastPktMsAgo;
  final int? rejected;
}

class HwHealth {
  const HwHealth({this.clients, this.heap, this.firmware});

  factory HwHealth.fromJson(Map<String, dynamic> j) =>
      HwHealth(clients: _int(j['clients']), heap: _int(j['heap']), firmware: _str(j['fw']));

  final int? clients;
  final int? heap;
  final String? firmware;
}

class HwState {
  const HwState({
    this.id,
    this.seq,
    this.uptimeMs,
    this.mode,
    this.ctrl,
    this.phase,
    this.interval,
    this.signals = const {},
    this.timing = const HwTiming(),
    this.plan = const {},
    this.approaches = const {},
    this.vehicles = const [],
    this.demand = const {},
    this.totalVehicles,
    this.congestion,
    this.preempt = const HwPreempt(),
    this.v2i = const HwV2i(),
    this.health = const HwHealth(),
  });

  factory HwState.fromJson(Map<String, dynamic> j) {
    final signals = _map(j['signals']);
    final plan = _map(j['plan']);
    final appr = _map(j['approaches']);
    final demand = _map(j['demand']);
    final vehicles = j['vehicles'];
    return HwState(
      id: _str(j['id']),
      seq: _int(j['seq']),
      uptimeMs: _int(j['uptime_ms']),
      mode: _lower(j['mode']),
      ctrl: _lower(j['ctrl']),
      phase: _str(j['phase'])?.toUpperCase(),
      interval: _lower(j['interval']),
      signals: {for (final e in signals.entries) e.key.toUpperCase(): _str(e.value)?.toUpperCase()},
      timing: HwTiming.fromJson(_map(j['timing'])),
      plan: {for (final e in plan.entries) e.key.toUpperCase(): HwPhasePlan.fromJson(_map(e.value))},
      approaches: {for (final e in appr.entries) e.key.toUpperCase(): HwApproach.fromJson(_map(e.value))},
      vehicles: vehicles is List ? [for (final v in vehicles) if (v is Map) HwVehicle.fromJson(_map(v))] : const [],
      demand: {for (final e in demand.entries) e.key.toUpperCase(): _int(e.value)},
      totalVehicles: _int(j['total_vehicles']),
      congestion: _lower(j['congestion']),
      preempt: HwPreempt.fromJson(_map(j['preempt'])),
      v2i: HwV2i.fromJson(_map(j['v2i'])),
      health: HwHealth.fromJson(_map(j['health'])),
    );
  }

  final String? id;
  final int? seq;
  final int? uptimeMs;

  /// "fixed" | "adaptive"
  final String? mode;

  /// "startup" | "normal" | "rest" | "idle" | "preempt" | "fallback" | "fault"
  final String? ctrl;

  /// "NS" | "EW" | "NONE"
  final String? phase;

  /// "green" | "yellow" | "all_red" | "startup" | "flash"
  final String? interval;

  /// Lamp per approach: "R" | "Y" | "G" | "OFF" (null when missing).
  final Map<String, String?> signals;
  final HwTiming timing;
  final Map<String, HwPhasePlan> plan;
  final Map<String, HwApproach> approaches;
  final List<HwVehicle> vehicles;
  final Map<String, int?> demand;
  final int? totalVehicles;

  /// "free" | "low" | "medium" | "high"
  final String? congestion;
  final HwPreempt preempt;
  final HwV2i v2i;
  final HwHealth health;

  bool get isAdaptive => mode == 'adaptive';
  bool get isFixed => mode == 'fixed';
  bool get preemptActive => preempt.active == true;

  /// The amber "fixed-time fallback" condition.
  bool get v2iLost => ctrl == 'fallback' || v2i.link == 'lost';
}

// --- event frame -------------------------------------------------------------------------

class HwEvent {
  const HwEvent({this.seq, this.uptimeMs, this.event, this.detail});

  factory HwEvent.fromJson(Map<String, dynamic> j) =>
      HwEvent(seq: _int(j['seq']), uptimeMs: _int(j['uptime_ms']), event: _lower(j['event']), detail: _str(j['detail']));

  final int? seq;
  final int? uptimeMs;

  /// "phase_change" | "mode_change" | "ev_request" | "preempt_start" | "preempt_end" |
  /// "v2i_lost" | "v2i_restored" | "restart"
  final String? event;
  final String? detail;
}

/// An "ev_request" detail such as "V05 E granted".
class EvRequest {
  const EvRequest({this.vehicleId, this.approach, this.result, required this.detail});

  factory EvRequest.parse(String? detail) {
    final text = (detail ?? '').trim();
    final m = RegExp(r'^(\S+)\s+([NSEWnsew])\b\s*(\S+)?').firstMatch(text);
    if (m == null) return EvRequest(detail: text);
    return EvRequest(vehicleId: m.group(1), approach: m.group(2)!.toUpperCase(), result: m.group(3)?.toLowerCase(), detail: text);
  }

  final String? vehicleId;
  final String? approach;

  /// "granted" | "rejected" | other text from the controller.
  final String? result;
  final String detail;
}
