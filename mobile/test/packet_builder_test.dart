import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/services/packet_builder.dart';

GpsFix fix(int second, {double lat = 31.5204, double lon = 74.33, double acc = 5, double? speed = 10, double? speedAcc = 0.5, double? heading = 90}) =>
    GpsFix(
      time: DateTime.utc(2026, 9, 30, 12, 0, second),
      lat: lat,
      lon: lon,
      accuracyM: acc,
      speedMps: speed,
      speedAccuracyMps: speedAcc,
      headingDeg: heading,
    );

void main() {
  test('builds a v1 packet with SI units and UTC time', () {
    final p = PacketBuilder().build(fix(0), 7, emergency: false)!;
    expect(p['seq'], 7);
    expect(p['recordedAt'], '2026-09-30T12:00:00.000Z');
    expect(p['speedMps'], 10.0);
    expect(p['speedSource'], 'GPS');
    expect(p['headingDeg'], 90.0);
    expect(p['emergency'], false);
    expect(p['mocked'], false);
    expect(p.containsKey('vehicleId'), isFalse); // the vehicle comes from the URL, not the packet
  });

  test('drops fixes that are too inaccurate to be useful', () {
    expect(PacketBuilder().build(fix(0, acc: 150), 0, emergency: false), isNull);
    expect(PacketBuilder().build(fix(0, acc: 0), 0, emergency: false), isNull);
  });

  test('drops fixes closer together than the minimum interval', () {
    final b = PacketBuilder();
    expect(b.build(fix(0), 0, emergency: false), isNotNull);
    expect(b.build(GpsFix(time: DateTime.utc(2026, 9, 30, 12, 0, 0, 500), lat: 31.52, lon: 74.33, accuracyM: 5), 1, emergency: false), isNull);
  });

  test('derives speed from consecutive fixes when the platform reports none', () {
    final b = PacketBuilder();
    b.build(fix(0, speed: 0, speedAcc: 0), 0, emergency: false);
    // 0.0001 deg of longitude at 31.52 N is about 9.5 m, over 1 s
    final p = b.build(fix(1, lon: 74.3301, speed: 0, speedAcc: 0), 1, emergency: false)!;
    expect(p['speedSource'], 'DERIVED');
    expect(p['speedMps'], closeTo(9.5, 0.3));
  });

  test('unknown speed stays null instead of zero', () {
    final p = PacketBuilder().build(fix(0, speed: 0, speedAcc: 0), 0, emergency: false)!;
    expect(p['speedMps'], isNull);
    expect(p['speedSource'], isNull);
  });

  test('stationary heading is removed and impossible speed is dropped', () {
    final b = PacketBuilder();
    final slow = b.build(fix(0, speed: 0.3, heading: 200), 0, emergency: false)!;
    expect(slow['headingDeg'], isNull);
    final fast = b.build(fix(2, speed: 95), 1, emergency: false)!;
    expect(fast['speedMps'], isNull);
  });

  test('gps quality classes', () {
    expect(gpsQualityFor(8), GpsQuality.excellent);
    expect(gpsQualityFor(20), GpsQuality.good);
    expect(gpsQualityFor(45), GpsQuality.fair);
    expect(gpsQualityFor(80), GpsQuality.poor);
  });
}
