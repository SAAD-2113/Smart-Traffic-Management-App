import 'json.dart';

class EmergencyEvent {
  EmergencyEvent(this.j);
  final Json j;
  String get id => j['id'] as String;
  String get vehicleId => j['vehicleId'] as String;
  String get vehicleCode => j['vehicleCode'] as String;
  String get vehicleType => j['vehicleType'] as String;
  bool get isSimulated => j['isSimulated'] as bool? ?? false;
  String get status => j['status'] as String;
  DateTime get startedAt => parseTime(j['startedAt'])!;
  DateTime? get endedAt => parseTime(j['endedAt']);
  String? get endReason => j['endReason'] as String?;
  double get durationS => toDouble(j['durationS']) ?? 0;
  bool get isActive => status == 'ACTIVE';
}

class ActiveEmergency extends EmergencyEvent {
  ActiveEmergency(super.j);
  double? get lat => toDouble(j['lat']);
  double? get lon => toDouble(j['lon']);
  double? get speedMps => toDouble(j['speedMps']);
  double? get headingDeg => toDouble(j['headingDeg']);
  DateTime? get lastFixAt => parseTime(j['lastFixAt']);
  String? get intersectionCode => j['intersectionCode'] as String?;
  String? get approachName => j['approachName'] as String?;
  String? get nextIntersectionCode => j['nextIntersectionCode'] as String?;
  double? get etaS => toDouble(j['etaS']);
}

class EmergencyStatus {
  EmergencyStatus(this.j);
  final Json j;
  String get vehicleType => j['vehicleType'] as String;
  bool get eligibleType => j['eligibleType'] as bool;
  String? get authorizationStatus => j['authorizationStatus'] as String?;
  bool get authorized => j['authorized'] as bool;
  DateTime? get validUntil => parseTime(j['authorizationValidUntil']);
  EmergencyEvent? get activeEvent => j['activeEvent'] == null ? null : EmergencyEvent(j['activeEvent'] as Json);
}

class AuthorizationRequest {
  AuthorizationRequest(this.j);
  final Json j;
  String get id => j['id'] as String;
  String get vehicleId => j['vehicleId'] as String;
  String get vehicleCode => j['vehicleCode'] as String;
  String get vehicleType => j['vehicleType'] as String;
  String? get registrationNumber => j['registrationNumber'] as String?;
  String get status => j['status'] as String;
  DateTime get requestedAt => parseTime(j['requestedAt'])!;
  DateTime? get reviewedAt => parseTime(j['reviewedAt']);
  DateTime? get validUntil => parseTime(j['validUntil']);
  String? get notes => j['notes'] as String?;
}
