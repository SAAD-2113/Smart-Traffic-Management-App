import 'json.dart';

/// Signal-control models: fixed-time / adaptive mode, why, and with which timing.
/// Values come from the backend; nothing here is computed from assumptions in the app.

class PhaseTiming {
  PhaseTiming(this.j);
  final Json j;
  String get phase => j['phase'] as String;
  List<String> get approaches => ((j['approaches'] as List?) ?? const []).cast<String>();
  double get greenS => toDouble(j['greenS']) ?? 0;
  double get yellowS => toDouble(j['yellowS']) ?? 0;
  double get allRedS => toDouble(j['allRedS']) ?? 0;
  double get redS => toDouble(j['redS']) ?? 0;
}

class TrafficBasis {
  TrafficBasis(this.j);
  final Json j;
  String get congestionLevel => j['congestionLevel'] as String;
  String? get averagedLevel => j['averagedLevel'] as String?;
  String get dataQuality => j['dataQuality'] as String;
  int get vehicleCount => toInt(j['vehicleCount']);
  double? get estimatedVehicleCount => toDouble(j['estimatedVehicleCount']);
  double? get avgSpeedMps => toDouble(j['avgSpeedMps']);
  double? get avgWaitingTimeS => toDouble(j['avgWaitingTimeS']);
  double get windowS => toDouble(j['windowS']) ?? 60;
  double? get windowVehicleCount => toDouble(j['windowVehicleCount']);
  double? get windowAvgSpeedMps => toDouble(j['windowAvgSpeedMps']);
  double? get windowAvgWaitingTimeS => toDouble(j['windowAvgWaitingTimeS']);
  String? get worstApproach => j['worstApproach'] as String?;
  String? get worstApproachLevel => j['worstApproachLevel'] as String?;
  int get worstApproachVehicles => toInt(j['worstApproachVehicles']);
}

class PendingSwitch {
  PendingSwitch(this.j);
  final Json j;
  String get toMode => j['toMode'] as String;
  double get inS => toDouble(j['inS']) ?? 0;
  String get condition => j['condition'] as String;
}

class ControlStatus {
  ControlStatus(this.j);
  final Json j;
  String get policy => j['policy'] as String;
  String get mode => j['mode'] as String;
  String get baseMode => j['baseMode'] as String;
  String get reason => j['reason'] as String;
  String get headline => j['headline'] as String;
  String get detail => j['detail'] as String;
  DateTime get since => parseTime(j['since'])!;
  PendingSwitch? get pending => j['pending'] == null ? null : PendingSwitch(j['pending'] as Json);
  TrafficBasis get traffic => TrafficBasis(j['traffic'] as Json);
  List<PhaseTiming> get fixedTiming => jsonList(j['fixedTiming']).map(PhaseTiming.new).toList();
  double get fixedCycleS => toDouble(j['fixedCycleS']) ?? 0;
  List<PhaseTiming> get activeTiming => jsonList(j['activeTiming']).map(PhaseTiming.new).toList();
  double get activeCycleS => toDouble(j['activeCycleS']) ?? 0;
  String? get algorithm => j['algorithm'] as String?;
  String? get priorityPhase => j['priorityPhase'] as String?;

  bool get isAdaptive => mode == 'ADAPTIVE';
  bool get isEmergency => mode == 'EMERGENCY_PRIORITY';
  bool get timingChanged => isAdaptive || isEmergency;
}

class SignalHead {
  SignalHead(this.j);
  final Json j;
  String get approach => j['approach'] as String;
  double get bearingDeg => toDouble(j['bearingDeg']) ?? 0;
  String get light => j['light'] as String; // GREEN / YELLOW / RED / OFF
}

/// What the lights show right now: a connected controller's report, or the server's
/// virtual controller when no hardware is connected (`virtual`).
class SignalDisplay {
  SignalDisplay(this.j);
  final Json j;
  String get source => j['source'] as String;
  bool get virtual => j['virtual'] as bool? ?? false;
  String get phaseName => j['phaseName'] as String;
  String get state => j['state'] as String;
  double? get remainingS => toDouble(j['remainingS']);
  String get mode => j['mode'] as String;
  DateTime get reportedAt => parseTime(j['reportedAt'])!;
  List<SignalHead> get heads => jsonList(j['heads']).map(SignalHead.new).toList();

  /// Seconds left in the current interval at [serverNow] (server clock).
  double? remainingAt(DateTime serverNow) {
    final r = remainingS;
    if (r == null) return null;
    final elapsed = serverNow.difference(reportedAt).inMilliseconds / 1000.0;
    return (r - elapsed).clamp(0, 999).toDouble();
  }
}

class ModeEvent {
  ModeEvent(this.j);
  final Json j;
  String get intersectionCode => (j['intersectionCode'] as String?) ?? '?';
  DateTime get at => parseTime(j['at'])!;
  String get fromMode => j['fromMode'] as String;
  String get toMode => j['toMode'] as String;
  String get reason => j['reason'] as String;
  String get headline => j['headline'] as String;
  String get detail => j['detail'] as String;
  TrafficBasis? get traffic => j['traffic'] == null ? null : TrafficBasis(j['traffic'] as Json);

  /// A MODE_CHANGED live event has the same fields under slightly different names.
  factory ModeEvent.fromLive(Json data) => ModeEvent({
        'intersectionCode': data['intersectionCode'],
        'at': data['at'],
        'fromMode': data['fromMode'],
        'toMode': data['toMode'],
        'reason': data['reason'],
        'headline': data['headline'],
        'detail': data['detail'],
      });
}

class ControlConfig {
  ControlConfig(this.j);
  final Json j;
  String get enterLevel => j['enterLevel'] as String;
  String get exitLevel => j['exitLevel'] as String;
  double get windowS => toDouble(j['windowS']) ?? 60;
  double get enterHoldS => toDouble(j['enterHoldS']) ?? 0;
  double get exitHoldS => toDouble(j['exitHoldS']) ?? 0;
  double get minAdaptiveS => toDouble(j['minAdaptiveS']) ?? 0;
  String get minDataQuality => j['minDataQuality'] as String;
  double get minVehicles => toDouble(j['minVehicles']) ?? 0;
  List<String> get rules => ((j['rules'] as List?) ?? const []).cast<String>();
}

String modeLabel(String mode) => switch (mode) {
      'FIXED_TIME' => 'Fixed-time',
      'ADAPTIVE' => 'Adaptive',
      'EMERGENCY_PRIORITY' => 'Emergency priority',
      _ => mode,
    };

String policyLabel(String policy) => switch (policy) {
      'AUTO' => 'Automatic',
      'FIXED' => 'Fixed-time only',
      'ADAPTIVE' => 'Adaptive only',
      _ => policy,
    };

String policyDescription(String policy) => switch (policy) {
      'AUTO' => 'Fixed-time while traffic is normal; switches to adaptive timing when congestion builds up.',
      'FIXED' => 'Always runs the configured fixed-time plan.',
      'ADAPTIVE' => 'Always calculates timing from current traffic.',
      _ => '',
    };

/// "Northbound+Southbound" -> "N/S"; other phase names are kept.
String shortPhase(String name) {
  final parts = name.split('+').map((p) => p.trim()).toList();
  const initials = {'Northbound': 'N', 'Southbound': 'S', 'Eastbound': 'E', 'Westbound': 'W'};
  if (parts.length > 1 && parts.every(initials.containsKey)) return parts.map((p) => initials[p]).join('/');
  return name;
}
