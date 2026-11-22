import '../../data/models/json.dart';

/// What this account may do in Digital V2I, as decided by the server from its stored role.
class V2IMe {
  V2IMe({
    required this.role,
    required this.canHost,
    required this.canDrive,
    this.vehicleId,
    this.emergencyStatus,
    this.emergency = false,
  });

  factory V2IMe.fromJson(Json j) => V2IMe(
        role: j['role'] as String,
        canHost: j['canHost'] as bool? ?? false,
        canDrive: j['canDrive'] as bool? ?? false,
        vehicleId: j['vehicleId'] as int?,
        emergencyStatus: j['emergencyStatus'] as String?,
        emergency: j['emergency'] as bool? ?? false,
      );

  final String role;
  final bool canHost;
  final bool canDrive;

  /// V2I vehicle id assigned by the server (1001..65535), drivers only.
  final int? vehicleId;

  /// NONE | REQUESTED | APPROVED | REJECTED | REVOKED.
  final String? emergencyStatus;

  /// The account may send "ty":1 (approved by an admin).
  final bool emergency;
}

/// A digital intersection hosted by this phone.
class HostedSession {
  HostedSession({
    required this.id,
    required this.name,
    required this.joinCode,
    required this.centerLat,
    required this.centerLon,
    required this.status,
    required this.createdAt,
    this.members = 0,
    this.onlineVehicles = 0,
    this.intersectionOnline = false,
  });

  factory HostedSession.fromJson(Json j) => HostedSession(
        id: j['id'] as String,
        name: j['name'] as String,
        joinCode: j['joinCode'] as String,
        centerLat: toDouble(j['centerLat'])!,
        centerLon: toDouble(j['centerLon'])!,
        status: j['status'] as String,
        createdAt: parseTime(j['createdAt'])!,
        members: toInt(j['members']),
        onlineVehicles: toInt(j['onlineVehicles']),
        intersectionOnline: j['intersectionOnline'] as bool? ?? false,
      );

  final String id;
  final String name;
  final String joinCode;
  final double centerLat;
  final double centerLon;
  final String status;
  final DateTime createdAt;
  final int members;
  final int onlineVehicles;
  final bool intersectionOnline;

  bool get isOpen => status == 'OPEN';
}

/// A session this driver joined (no join code, no host details).
class JoinedSession {
  JoinedSession({
    required this.sessionId,
    required this.name,
    required this.centerLat,
    required this.centerLon,
    required this.vehicleId,
    required this.emergency,
    this.intersectionOnline = false,
  });

  factory JoinedSession.fromJson(Json j) => JoinedSession(
        sessionId: j['sessionId'] as String,
        name: j['name'] as String,
        centerLat: toDouble(j['centerLat'])!,
        centerLon: toDouble(j['centerLon'])!,
        vehicleId: j['vehicleId'] as int,
        emergency: j['emergency'] as bool? ?? false,
        intersectionOnline: j['intersectionOnline'] as bool? ?? false,
      );

  final String sessionId;
  final String name;
  final double centerLat;
  final double centerLon;
  final int vehicleId;
  final bool emergency;
  final bool intersectionOnline;
}

/// One recorded point of the driver's own trip (for replay).
class TripPoint {
  TripPoint({required this.t, required this.lat, required this.lon, this.speedKmh, this.headingDeg});

  factory TripPoint.fromJson(Json j) => TripPoint(
        t: toDouble(j['t']) ?? 0,
        lat: toDouble(j['lat'])!,
        lon: toDouble(j['lon'])!,
        speedKmh: toDouble(j['speedKmh']),
        headingDeg: toDouble(j['headingDeg']),
      );

  /// Seconds since the trip's first point.
  final double t;
  final double lat;
  final double lon;
  final double? speedKmh;
  final double? headingDeg;
}

/// An account's V2I profile as an admin sees it.
class V2IProfileRow {
  V2IProfileRow({
    required this.fullName,
    required this.email,
    required this.vehicleId,
    required this.emergencyStatus,
    this.emergencyReason,
    this.requestedAt,
  });

  factory V2IProfileRow.fromJson(Json j) => V2IProfileRow(
        fullName: j['fullName'] as String,
        email: j['email'] as String,
        vehicleId: j['vehicleId'] as int,
        emergencyStatus: j['emergencyStatus'] as String,
        emergencyReason: j['emergencyReason'] as String?,
        requestedAt: parseTime(j['emergencyRequestedAt']),
      );

  final String fullName;
  final String email;
  final int vehicleId;
  final String emergencyStatus;
  final String? emergencyReason;
  final DateTime? requestedAt;
}
