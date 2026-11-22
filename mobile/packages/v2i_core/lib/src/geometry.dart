import 'dart:math' as math;

import 'cnum.dart';
import 'config.dart';

/// Junction geometry around a centre point (v2i_common.h). The firmware fixes the centre at
/// CENTER_LAT / CENTER_LON; the digital twin takes it from the session.
class Geometry {
  const Geometry({this.centerLat = CENTER_LAT, this.centerLon = CENTER_LON});

  final double centerLat;
  final double centerLon;

  /// Metres per degree of longitude at the centre.
  double mPerDegLon() => 111320.0 * math.cos(centerLat * math.pi / 180.0);

  /// Metres east (x) and north (y) of the centre.
  (double x, double y) latlonToXY(double lat, double lon) =>
      ((lon - centerLon) * mPerDegLon(), (lat - centerLat) * M_PER_DEG_LAT);

  (double lat, double lon) xyToLatLon(double x, double y) => (centerLat + y / M_PER_DEG_LAT, centerLon + x / mPerDegLon());

  @override
  bool operator ==(Object other) => other is Geometry && other.centerLat == centerLat && other.centerLon == centerLon;

  @override
  int get hashCode => Object.hash(centerLat, centerLon);
}

/// Smallest absolute angle between two bearings (degrees, 0..180), computed in float.
double angDiff(double a, double b) {
  final d = f32(cfmod(f32(f32(a - b) + 540.0), 360.0) - 180.0);
  return d.abs();
}

double wrap360(double a) {
  final r = f32(cfmod(f32(a), 360.0));
  return r < 0 ? f32(r + 360.0) : r;
}

/// "N" -> 0 ... ; -1 if unknown.
int laneIndex(String? name) => name == null ? -1 : LANE_NAME.indexOf(name);
