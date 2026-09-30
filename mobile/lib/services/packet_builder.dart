import 'dart:math' as math;

import '../data/models/json.dart';

/// One raw GNSS fix, independent of the location plugin.
class GpsFix {
  GpsFix({
    required this.time,
    required this.lat,
    required this.lon,
    required this.accuracyM,
    this.speedMps,
    this.speedAccuracyMps,
    this.headingDeg,
    this.altitudeM,
    this.mocked = false,
  });

  final DateTime time; // UTC time of the fix (from the GNSS receiver)
  final double lat;
  final double lon;
  final double accuracyM;
  final double? speedMps;
  final double? speedAccuracyMps;
  final double? headingDeg;
  final double? altitudeM;
  final bool mocked;
}

enum GpsQuality { excellent, good, fair, poor }

GpsQuality gpsQualityFor(double accuracyM) {
  if (accuracyM <= 10) return GpsQuality.excellent;
  if (accuracyM <= 25) return GpsQuality.good;
  if (accuracyM <= 50) return GpsQuality.fair;
  return GpsQuality.poor;
}

/// Turns GNSS fixes into telemetry packets (the v1 packet format in docs/ARCHITECTURE.md).
///
/// Rules applied on the phone (the server re-validates everything):
/// - fixes worse than [maxAccuracyToSendM] are not sent; the UI shows "GPS poor";
/// - timestamps must increase and be at least [minIntervalS] apart;
/// - when the platform reports no speed, speed is derived from the previous good fix
///   and marked DERIVED; otherwise it is left null (unknown is not zero);
/// - heading is only sent while moving, because a stationary heading is noise.
class PacketBuilder {
  static const maxAccuracyToSendM = 100.0;
  static const minIntervalS = 0.9;
  static const derivedSpeedMaxAccuracyM = 25.0;
  static const maxPlausibleSpeedMps = 70.0;
  static const headingMinSpeedMps = 1.0;

  GpsFix? _lastSent;
  GpsFix? _lastGood;

  static double distanceM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371008.8;
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
    final a = math.pow(math.sin(dp / 2), 2) + math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }

  /// Returns the packet to queue, or null when this fix should not be sent.
  Json? build(GpsFix fix, int seq, {required bool emergency}) {
    if (!fix.accuracyM.isFinite || fix.accuracyM <= 0 || fix.accuracyM > maxAccuracyToSendM) return null;
    if (!fix.lat.isFinite || !fix.lon.isFinite) return null;
    final last = _lastSent;
    if (last != null && fix.time.difference(last.time).inMilliseconds < minIntervalS * 1000) return null;

    String? speedSource;
    double? speed;
    final platformSpeed = fix.speedMps;
    if (platformSpeed != null && platformSpeed >= 0 && (platformSpeed > 0 || (fix.speedAccuracyMps ?? 0) > 0)) {
      speed = platformSpeed;
      speedSource = 'GPS';
    } else if (_lastGood != null && fix.accuracyM <= derivedSpeedMaxAccuracyM) {
      final dt = fix.time.difference(_lastGood!.time).inMilliseconds / 1000.0;
      if (dt >= 1 && dt <= 10) {
        speed = distanceM(_lastGood!.lat, _lastGood!.lon, fix.lat, fix.lon) / dt;
        speedSource = 'DERIVED';
      }
    }
    if (speed != null && speed > maxPlausibleSpeedMps) {
      speed = null; // the server would reject it; better to say "unknown"
      speedSource = null;
    }

    double? heading = fix.headingDeg;
    if (heading != null && (heading < 0 || heading >= 360 || !heading.isFinite)) heading = null;
    if (speed == null || speed < headingMinSpeedMps) heading = null;

    double? altitude = fix.altitudeM;
    if (altitude != null && (!altitude.isFinite || altitude < -500 || altitude > 9000)) altitude = null;

    _lastSent = fix;
    if (fix.accuracyM <= derivedSpeedMaxAccuracyM) _lastGood = fix;

    return {
      'seq': seq,
      'recordedAt': fix.time.toUtc().toIso8601String(),
      'lat': fix.lat,
      'lon': fix.lon,
      'accuracyM': double.parse(fix.accuracyM.toStringAsFixed(1)),
      'speedMps': speed == null ? null : double.parse(speed.toStringAsFixed(2)),
      if (fix.speedAccuracyMps != null && fix.speedAccuracyMps! > 0) 'speedAccuracyMps': fix.speedAccuracyMps,
      'speedSource': speedSource,
      'headingDeg': heading == null ? null : double.parse(heading.toStringAsFixed(1)),
      'altitudeM': altitude == null ? null : double.parse(altitude.toStringAsFixed(1)),
      'emergency': emergency,
      'mocked': fix.mocked,
    };
  }
}
