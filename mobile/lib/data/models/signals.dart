import 'json.dart';
import 'traffic.dart';

class PhaseConfig {
  PhaseConfig({
    required this.name,
    required this.approaches,
    required this.minGreenS,
    required this.maxGreenS,
    required this.fixedGreenS,
    required this.yellowS,
    required this.allRedS,
  });

  factory PhaseConfig.fromJson(Json j) => PhaseConfig(
        name: j['name'] as String,
        approaches: ((j['approaches'] as List?) ?? const []).cast<String>(),
        minGreenS: toDouble(j['minGreenS'])!,
        maxGreenS: toDouble(j['maxGreenS'])!,
        fixedGreenS: toDouble(j['fixedGreenS'])!,
        yellowS: toDouble(j['yellowS'])!,
        allRedS: toDouble(j['allRedS'])!,
      );

  String name;
  List<String> approaches;
  double minGreenS;
  double maxGreenS;
  double fixedGreenS;
  double yellowS;
  double allRedS;

  Json toJson() => {
        'name': name,
        'approaches': approaches,
        'minGreenS': minGreenS,
        'maxGreenS': maxGreenS,
        'fixedGreenS': fixedGreenS,
        'yellowS': yellowS,
        'allRedS': allRedS,
      };
}

class SignalPlanConfig {
  SignalPlanConfig(this.j)
      : phases = jsonList(j['phases']).map(PhaseConfig.fromJson).toList(),
        minCycleS = toDouble(j['minCycleS'])!,
        maxCycleS = toDouble(j['maxCycleS'])!;

  final Json j;
  final List<PhaseConfig> phases;
  double minCycleS;
  double maxCycleS;

  String get intersectionId => j['intersectionId'] as String;
  String get intersectionCode => j['intersectionCode'] as String;
  bool get isDefault => j['isDefault'] as bool;
  double get fixedCycleS => toDouble(j['fixedCycleS'])!;
  double get lostTimeS => toDouble(j['lostTimeS'])!;

  Json toJson() => {'phases': phases.map((p) => p.toJson()).toList(), 'minCycleS': minCycleS, 'maxCycleS': maxCycleS};
}

class SignalOverviewItem {
  SignalOverviewItem(this.j);
  final Json j;
  String get intersectionId => j['intersectionId'] as String;
  String get code => j['code'] as String;
  String get name => j['name'] as String;
  String get controllerType => j['controllerType'] as String;
  String get actuator => j['actuator'] as String;
  bool get connected => j['connected'] as bool;
  SignalPlanConfig get plan => SignalPlanConfig(j['plan'] as Json);
  SignalDecisionInfo? get decision => j['decision'] == null ? null : SignalDecisionInfo(j['decision'] as Json);
  SignalStateInfo? get state => j['state'] == null ? null : SignalStateInfo(j['state'] as Json);
}

class IntersectionConfig {
  IntersectionConfig(this.j);
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
  double get penetrationRate => toDouble(j['assumedPenetrationRate']) ?? 0.05;
  List<Json> get approaches => jsonList(j['approaches']);
  List<Json> get outgoingLinks => jsonList(j['outgoingLinks']);
}

class DemoStatus {
  DemoStatus(this.j);
  final Json j;
  bool get enabled => j['enabled'] as bool;
  bool get running => j['running'] as bool;
  int get vehicles => toInt(j['vehicles']);
  int get activeVehicles => toInt(j['activeVehicles']);
  bool get emergencyActive => j['emergencyActive'] as bool;
  double get simulatedSeconds => toDouble(j['simulatedSeconds']) ?? 0;
}
