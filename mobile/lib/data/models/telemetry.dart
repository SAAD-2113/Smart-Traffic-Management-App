import 'json.dart';

class TrackingSession {
  TrackingSession({
    required this.id,
    required this.startedAt,
    this.endedAt,
    this.endReason,
    required this.packetCount,
    required this.rejectedCount,
    required this.distanceM,
    this.maxSpeedMps,
    this.avgSpeedMps,
    required this.durationS,
  });

  factory TrackingSession.fromJson(Json j) => TrackingSession(
        id: j['id'] as String,
        startedAt: parseTime(j['startedAt'])!,
        endedAt: parseTime(j['endedAt']),
        endReason: j['endReason'] as String?,
        packetCount: toInt(j['packetCount']),
        rejectedCount: toInt(j['rejectedCount']),
        distanceM: toDouble(j['distanceM']) ?? 0,
        maxSpeedMps: toDouble(j['maxSpeedMps']),
        avgSpeedMps: toDouble(j['avgSpeedMps']),
        durationS: toDouble(j['durationS']) ?? 0,
      );

  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? endReason;
  final int packetCount;
  final int rejectedCount;
  final double distanceM;
  final double? maxSpeedMps;
  final double? avgSpeedMps;
  final double durationS;

  bool get isOpen => endedAt == null;
}

class LiveState {
  LiveState({
    required this.recordedAt,
    required this.ageS,
    required this.lat,
    required this.lon,
    required this.accuracyM,
    required this.gpsQuality,
    this.speedMps,
    this.headingDeg,
    required this.emergency,
    required this.usable,
    required this.source,
    this.intersectionCode,
    this.approachName,
    this.zone,
  });

  factory LiveState.fromJson(Json j) => LiveState(
        recordedAt: parseTime(j['recordedAt'])!,
        ageS: toDouble(j['ageS']) ?? 0,
        lat: toDouble(j['lat'])!,
        lon: toDouble(j['lon'])!,
        accuracyM: toDouble(j['accuracyM'])!,
        gpsQuality: j['gpsQuality'] as String,
        speedMps: toDouble(j['speedMps']),
        headingDeg: toDouble(j['headingDeg']),
        emergency: j['emergency'] as bool,
        usable: j['usable'] as bool,
        source: j['source'] as String,
        intersectionCode: j['intersectionCode'] as String?,
        approachName: j['approachName'] as String?,
        zone: j['zone'] as String?,
      );

  final DateTime recordedAt;
  final double ageS;
  final double lat;
  final double lon;
  final double accuracyM;
  final String gpsQuality;
  final double? speedMps;
  final double? headingDeg;
  final bool emergency;
  final bool usable;
  final String source;
  final String? intersectionCode;
  final String? approachName;
  final String? zone;
}

class LiveVehicle {
  LiveVehicle({
    required this.vehicleId,
    required this.code,
    required this.vehicleType,
    required this.isSimulated,
    required this.emergencyAuthorized,
    required this.emergencyActive,
    required this.trackingStatus,
    this.live,
  });

  factory LiveVehicle.fromJson(Json j) => LiveVehicle(
        vehicleId: j['vehicleId'] as String,
        code: j['code'] as String,
        vehicleType: j['vehicleType'] as String,
        isSimulated: j['isSimulated'] as bool,
        emergencyAuthorized: j['emergencyAuthorized'] as bool,
        emergencyActive: j['emergencyActive'] as bool,
        trackingStatus: j['trackingStatus'] as String,
        live: j['live'] == null ? null : LiveState.fromJson(j['live'] as Json),
      );

  final String vehicleId;
  final String code;
  final String vehicleType;
  final bool isSimulated;
  final bool emergencyAuthorized;
  final bool emergencyActive;
  final String trackingStatus; // TRANSMITTING, STALE, NOT_TRACKING
  final LiveState? live;

  bool get isTransmitting => trackingStatus == 'TRANSMITTING';
}

class TrackPoint {
  TrackPoint({required this.recordedAt, required this.lat, required this.lon, this.speedMps, required this.isLive});

  factory TrackPoint.fromJson(Json j) => TrackPoint(
        recordedAt: parseTime(j['recordedAt'])!,
        lat: toDouble(j['lat'])!,
        lon: toDouble(j['lon'])!,
        speedMps: toDouble(j['speedMps']),
        isLive: j['isLive'] as bool,
      );

  final DateTime recordedAt;
  final double lat;
  final double lon;
  final double? speedMps;
  final bool isLive;
}

class PacketResult {
  PacketResult({required this.seq, required this.accepted, this.reason});

  factory PacketResult.fromJson(Json j) =>
      PacketResult(seq: toInt(j['seq']), accepted: j['status'] == 'ACCEPTED', reason: j['reason'] as String?);

  final int seq;
  final bool accepted;
  final String? reason;
}

class TelemetryUploadResult {
  TelemetryUploadResult({required this.accepted, required this.rejected, required this.results, required this.emergencyActive});

  factory TelemetryUploadResult.fromJson(Json j) => TelemetryUploadResult(
        accepted: toInt(j['accepted']),
        rejected: toInt(j['rejected']),
        results: jsonList(j['results']).map(PacketResult.fromJson).toList(),
        emergencyActive: j['emergencyActive'] as bool,
      );

  final int accepted;
  final int rejected;
  final List<PacketResult> results;
  final bool emergencyActive;
}
