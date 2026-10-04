import 'control.dart';
import 'json.dart';

class ObservedStats {
  ObservedStats(this.j);
  final Json j;
  int get vehicleCount => toInt(j['vehicleCount']);
  int get stoppedCount => toInt(j['stoppedCount']);
  int get emergencyCount => toInt(j['emergencyCount']);
  int get speedSampleCount => toInt(j['speedSampleCount']);
  double? get avgSpeedMps => toDouble(j['avgSpeedMps']);
  double? get minSpeedMps => toDouble(j['minSpeedMps']);
  double? get maxSpeedMps => toDouble(j['maxSpeedMps']);
}

class CalculatedStats {
  CalculatedStats(this.j);
  final Json j;
  double? get speedRatio => toDouble(j['speedRatio']);
  double? get avgWaitingTimeS => toDouble(j['avgWaitingTimeS']);
  int get expectedArrivals60s => toInt(j['expectedArrivals60s']);
}

class EstimatedStats {
  EstimatedStats(this.j);
  final Json j;
  double? get vehicleCount => toDouble(j['vehicleCount']);
  double? get densityVehPerKmLane => toDouble(j['densityVehPerKmLane']);
  double get penetrationRate => toDouble(j['penetrationRate']) ?? 0.05;
}

class ApproachTraffic {
  ApproachTraffic(this.j);
  final Json j;
  String get name => j['name'] as String;
  ObservedStats get observed => ObservedStats(j['observed'] as Json);
  CalculatedStats get calculated => CalculatedStats(j['calculated'] as Json);
  EstimatedStats get estimated => EstimatedStats(j['estimated'] as Json);
  String get congestionLevel => j['congestionLevel'] as String;
  String get dataQuality => j['dataQuality'] as String;
  int? get detectorCount => j['detectorCount'] as int?;
  double? get maxWaitingTimeS => toDouble(j['maxWaitingTimeS']);
}

class SignalStateInfo {
  SignalStateInfo(this.j);
  final Json j;
  String get phaseName => j['phaseName'] as String;
  String get state => j['state'] as String;
  double? get remainingS => toDouble(j['remainingS']);
  String get mode => j['mode'] as String;
  DateTime get reportedAt => parseTime(j['reportedAt'])!;
  String get source => j['source'] as String;
}

class PhaseGreen {
  PhaseGreen(this.phase, this.greenS);
  final String phase;
  final double greenS;
}

class SignalDecisionInfo {
  SignalDecisionInfo(this.j);
  final Json j;
  String? get id => j['id'] as String?;
  String get algorithm => j['algorithm'] as String;
  double get cycleS => toDouble(j['cycleS'])!;
  List<PhaseGreen> get phaseGreens =>
      jsonList(j['phaseGreens']).map((g) => PhaseGreen(g['phase'] as String, toDouble(g['greenS'])!)).toList();
  String? get priorityPhase => j['priorityPhase'] as String?;
  String get reason => j['reason'] as String;
  DateTime get createdAt => parseTime(j['createdAt'])!;
  DateTime get validUntil => parseTime(j['validUntil'])!;
  Json get inputs => (j['inputs'] as Json?) ?? const {};

  String get algorithmLabel => switch (algorithm) {
        'DEMAND_PROPORTIONAL' => 'Demand-proportional (Webster-style)',
        'EMERGENCY_PRIORITY' => 'Emergency priority',
        'FIXED_TIME' => 'Fixed time',
        _ => algorithm,
      };
}

class UpstreamFlow {
  UpstreamFlow(this.j);
  final Json j;
  String get fromCode => j['fromCode'] as String;
  String? get toApproachName => j['toApproachName'] as String?;
  int get vehiclesOnLink => toInt(j['vehiclesOnLink']);
  int get expectedArrivals60s => toInt(j['expectedArrivals60s']);
  double get estimatedArrivals60s => toDouble(j['estimatedArrivals60s']) ?? 0;
  double? get avgSpeedMps => toDouble(j['avgSpeedMps']);
}

class DownstreamLoad {
  DownstreamLoad(this.j);
  final Json j;
  String get toCode => j['toCode'] as String;
  String get congestionLevel => j['congestionLevel'] as String;
  String get dataQuality => j['dataQuality'] as String;
}

class EmergencyNear {
  EmergencyNear(this.j);
  final Json j;
  String? get label => j['label'] as String?;
  String get vehicleType => j['vehicleType'] as String;
  String? get approachName => j['approachName'] as String?;
  double get distanceM => toDouble(j['distanceM']) ?? 0;
  double? get etaS => toDouble(j['etaS']);
}

class IntersectionTraffic {
  IntersectionTraffic(this.j);
  final Json j;
  String get id => j['id'] as String;
  String get code => j['code'] as String;
  String get name => j['name'] as String;
  double get latitude => toDouble(j['latitude'])!;
  double get longitude => toDouble(j['longitude'])!;
  double get radiusM => toDouble(j['radiusM'])!;
  double get approachRadiusM => toDouble(j['approachRadiusM'])!;
  String get status => j['status'] as String;
  String get controllerType => j['controllerType'] as String;
  String get actuator => j['actuator'] as String;
  String get congestionLevel => j['congestionLevel'] as String;
  String get dataQuality => j['dataQuality'] as String;
  bool get fullyObserved => j['fullyObserved'] as bool? ?? false;
  List<String> get sources => ((j['sources'] as List?) ?? const []).cast<String>();
  ObservedStats get observed => ObservedStats(j['observed'] as Json);
  CalculatedStats get calculated => CalculatedStats(j['calculated'] as Json);
  EstimatedStats get estimated => EstimatedStats(j['estimated'] as Json);
  int get coreCount => toInt(j['coreCount']);
  int get departureCount => toInt(j['departureCount']);
  List<ApproachTraffic> get approaches => jsonList(j['approaches']).map(ApproachTraffic.new).toList();
  List<UpstreamFlow> get upstream => jsonList(j['upstream']).map(UpstreamFlow.new).toList();
  List<DownstreamLoad> get downstream => jsonList(j['downstream']).map(DownstreamLoad.new).toList();
  List<EmergencyNear> get emergencies => jsonList(j['emergencies']).map(EmergencyNear.new).toList();
  SignalStateInfo? get signal => j['signal'] == null ? null : SignalStateInfo(j['signal'] as Json);
  bool get connected => j['connected'] as bool? ?? false;
  SignalDecisionInfo? get decision => j['decision'] == null ? null : SignalDecisionInfo(j['decision'] as Json);
  DateTime? get computedAt => parseTime(j['computedAt']);
  ControlStatus? get control => j['control'] == null ? null : ControlStatus(j['control'] as Json);
  SignalDisplay? get displaySignal => j['displaySignal'] == null ? null : SignalDisplay(j['displaySignal'] as Json);

  bool get isActive => status == 'ACTIVE';
  bool get isCongested => congestionLevel == 'HIGH' || congestionLevel == 'SEVERE';
}

class SystemStatus {
  SystemStatus(this.j);
  final Json j;
  String get database => j['database'] as String;
  bool get engineRunning => j['engineRunning'] as bool;
  DateTime? get engineLastCycleAt => parseTime(j['engineLastCycleAt']);
  double? get engineCycleMs => toDouble(j['engineCycleMs']);
  int get websocketClients => toInt(j['websocketClients']);
  bool get demoMode => j['demoMode'] as bool;
  bool get simulationRunning => j['simulationRunning'] as bool;
  List<String> get externalSources => ((j['externalSources'] as List?) ?? const []).cast<String>();
}

class TrafficOverview {
  TrafficOverview(this.j);
  final Json j;
  DateTime get generatedAt => parseTime(j['generatedAt'])!;
  int get totalRegisteredVehicles => toInt(j['totalRegisteredVehicles']);
  int get simulatedVehicles => toInt(j['simulatedVehicles']);
  int get activeVehicles => toInt(j['activeVehicles']);
  int get transmittingVehicles => toInt(j['transmittingVehicles']);
  int get emergencyVehicles => toInt(j['emergencyVehicles']);
  double? get averageSpeedMps => toDouble(j['averageSpeedMps']);
  double? get averageDensity => toDouble(j['averageDensityVehPerKmLane']);
  int get totalIntersections => toInt(j['totalIntersections']);
  int get activeIntersections => toInt(j['activeIntersections']);
  int get connectedIntersections => toInt(j['connectedIntersections']);
  int get congestedIntersections => toInt(j['congestedIntersections']);
  List<String> get congestedCodes => ((j['congestedIntersectionCodes'] as List?) ?? const []).cast<String>();
  int get pendingAuthorizations => toInt(j['pendingAuthorizations']);
  int get fixedTimeIntersections => toInt(j['fixedTimeIntersections']);
  int get adaptiveIntersections => toInt(j['adaptiveIntersections']);
  int get emergencyPriorityIntersections => toInt(j['emergencyPriorityIntersections']);
  SystemStatus get system => SystemStatus(j['system'] as Json);
}

class HistoryPoint {
  HistoryPoint(this.j);
  final Json j;
  DateTime get t => parseTime(j['t'])!;
  double? get observedVehicles => toDouble(j['observedVehicles']);
  double? get estimatedVehicles => toDouble(j['estimatedVehicles']);
  double? get avgSpeedMps => toDouble(j['avgSpeedMps']);
  double? get avgWaitingTimeS => toDouble(j['avgWaitingTimeS']);
  double? get congestionRank => toDouble(j['congestionRank']);
  String get worstCongestion => j['worstCongestion'] as String;
  int get emergencyCount => toInt(j['emergencyCount']);
}

class HistorySeries {
  HistorySeries(this.j);
  final Json j;
  String get code => j['code'] as String;
  String get intersectionId => j['intersectionId'] as String;
  List<HistoryPoint> get points => jsonList(j['points']).map(HistoryPoint.new).toList();
}
