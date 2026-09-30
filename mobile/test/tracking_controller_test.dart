import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/core/network/api_exception.dart';
import 'package:smart_traffic/data/local/telemetry_queue.dart';
import 'package:smart_traffic/data/models/json.dart';
import 'package:smart_traffic/data/models/telemetry.dart';
import 'package:smart_traffic/data/models/vehicle.dart';
import 'package:smart_traffic/data/repositories/vehicle_repository.dart';
import 'package:smart_traffic/services/location_service.dart';
import 'package:smart_traffic/services/packet_builder.dart';
import 'package:smart_traffic/services/tracking_controller.dart';

class FakeLocation implements LocationService {
  FakeLocation(this.access);
  final LocationAccess access;
  final fixesController = StreamController<GpsFix>.broadcast();

  @override
  Future<LocationAccess> ensureAccess() async => access;

  @override
  Stream<GpsFix> fixes({required String notificationTitle, required String notificationText}) => fixesController.stream;

  @override
  Stream<bool> serviceEnabledChanges() => const Stream.empty();

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;
}

class FakeRepo implements VehicleRepository {
  bool online = true;
  ApiException? failWith;
  final uploaded = <Json>[];
  bool stopped = false;

  @override
  String get installationId => 'test-installation';

  @override
  Future<TrackingSession> startTracking(String vehicleId) async => TrackingSession.fromJson({
        'id': 'session-1', 'startedAt': DateTime.now().toUtc().toIso8601String(), 'packetCount': 0,
        'rejectedCount': 0, 'distanceM': 0, 'durationS': 0,
      });

  @override
  Future<TelemetryUploadResult> upload(String vehicleId, String sessionId, List<Json> packets) async {
    if (failWith != null) throw failWith!;
    if (!online) throw ApiException.network('offline');
    uploaded.addAll(packets);
    return TelemetryUploadResult(
      accepted: packets.length,
      rejected: 0,
      results: [for (final p in packets) PacketResult(seq: p['seq'] as int, accepted: true)],
      emergencyActive: false,
    );
  }

  @override
  Future<void> stopTracking(String vehicleId, String? sessionId) async => stopped = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

final vehicle = OwnerVehicle.fromJson({
  'id': 'veh-1', 'code': 'VH-0001', 'vehicleType': 'NORMAL', 'displayName': 'Car', 'status': 'ACTIVE',
  'emergencyAuthorized': false, 'isSimulated': false,
});

GpsFix fixAt(DateTime t, int i) => GpsFix(time: t.toUtc(), lat: 31.52, lon: 74.33 + i * 0.0001, accuracyM: 5, speedMps: 10, speedAccuracyMps: 0.3, headingDeg: 90);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('permission denied does not start a session', () async {
    final repo = FakeRepo();
    final c = TrackingController(repository: repo, location: FakeLocation(LocationAccess.denied), queue: MemoryTelemetryQueue());
    await c.start(vehicle);
    expect(c.phase, TrackingPhase.idle);
    expect(c.gps, GpsStatus.permissionDenied);
    expect(c.error, contains('permission'));
    c.dispose();
  });

  test('offline packets are queued and delivered in order when back online', () async {
    final repo = FakeRepo()..online = false;
    final location = FakeLocation(LocationAccess.granted);
    final queue = MemoryTelemetryQueue();
    var now = DateTime.now();
    final c = TrackingController(repository: repo, location: location, queue: queue, clock: () => now);
    await c.start(vehicle);
    expect(c.phase, TrackingPhase.active);

    for (var i = 0; i < 5; i++) {
      location.fixesController.add(fixAt(now.add(Duration(seconds: i)), i));
    }
    await settle();
    expect(await queue.count(), 5);
    expect(c.gps, GpsStatus.excellent);

    await c.uploadNow();
    expect(c.link, LinkStatus.offline);
    expect(await queue.count(), 5); // nothing lost

    repo.online = true;
    await c.uploadNow(); // still inside the backoff window
    expect(repo.uploaded, isEmpty);
    now = now.add(const Duration(seconds: 3));
    await c.uploadNow();
    expect(repo.uploaded.map((p) => p['seq']), [0, 1, 2, 3, 4]);
    expect(await queue.count(), 0);
    expect(c.link, LinkStatus.online);
    expect(c.sent, 5);

    await c.stop();
    expect(repo.stopped, isTrue);
    expect(c.phase, TrackingPhase.idle);
    c.dispose();
  });

  test('a closed session stops tracking with a clear message', () async {
    final repo = FakeRepo();
    final location = FakeLocation(LocationAccess.granted);
    final c = TrackingController(repository: repo, location: location, queue: MemoryTelemetryQueue());
    await c.start(vehicle);
    location.fixesController.add(fixAt(DateTime.now(), 0));
    await settle();
    repo.failWith = ApiException(statusCode: 409, code: 'SESSION_NOT_ACTIVE', message: 'closed');
    await c.uploadNow();
    expect(c.phase, TrackingPhase.idle);
    expect(c.error, contains('closed by the server'));
    c.dispose();
  });

  test('packets older than the backfill window are discarded, not sent', () async {
    final repo = FakeRepo();
    final location = FakeLocation(LocationAccess.granted);
    final queue = MemoryTelemetryQueue();
    final c = TrackingController(repository: repo, location: location, queue: queue);
    await c.start(vehicle);
    await queue.add('session-1', 0, DateTime.now().toUtc().subtract(const Duration(minutes: 20)), {'seq': 0});
    await c.uploadNow();
    expect(repo.uploaded, isEmpty);
    expect(c.droppedOld, 1);
    c.dispose();
  });
}
