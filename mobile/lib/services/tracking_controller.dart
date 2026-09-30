import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/network/api_exception.dart';
import '../data/local/telemetry_queue.dart';
import '../data/models/telemetry.dart';
import '../data/models/vehicle.dart';
import '../data/repositories/vehicle_repository.dart';
import 'location_service.dart';
import 'packet_builder.dart';
import 'upload_policy.dart';

enum TrackingPhase { idle, starting, active, stopping }

enum GpsStatus { off, unsupported, permissionDenied, permissionDeniedForever, serviceDisabled, searching, excellent, good, fair, poor }

enum LinkStatus { unknown, online, offline, degraded }

/// Runs a tracking session: GPS fix → packet → local queue → batched upload.
///
/// The GPS callback never talks to the network. The uploader drains the queue every
/// two seconds, backs off when offline, and drops packets too old to be useful.
class TrackingController extends ChangeNotifier {
  TrackingController({
    required VehicleRepository repository,
    required LocationService location,
    required TelemetryQueue queue,
    DateTime Function()? clock,
  })  : _repo = repository,
        _locationService = location,
        _telemetryQueue = queue,
        _now = clock ?? DateTime.now;

  final VehicleRepository _repo;
  final LocationService _locationService;
  final TelemetryQueue _telemetryQueue;
  final DateTime Function() _now;

  TrackingPhase phase = TrackingPhase.idle;
  GpsStatus gps = GpsStatus.off;
  LinkStatus link = LinkStatus.unknown;
  String? error;
  OwnerVehicle? vehicle;
  TrackingSession? session;
  GpsFix? lastFix;
  DateTime? lastFixAt;
  DateTime? lastUploadAt;
  int queued = 0;
  int sent = 0;
  int rejected = 0;
  int droppedOld = 0;
  String? lastRejectReason;
  bool emergencyActive = false;
  double localDistanceM = 0;

  PacketBuilder _builder = PacketBuilder();
  int _seq = 0;
  int _failures = 0;
  DateTime? _nextAttempt;
  bool _uploading = false;
  StreamSubscription<GpsFix>? _fixSub;
  StreamSubscription<bool>? _serviceSub;
  Timer? _uploadTimer;
  Timer? _watchdog;

  bool get isActive => phase == TrackingPhase.active;
  bool get isBusy => phase == TrackingPhase.starting || phase == TrackingPhase.stopping;
  double? get speedMps => lastFix?.speedMps != null && lastFix!.speedMps! >= 0 ? lastFix!.speedMps : null;

  Future<void> start(OwnerVehicle v) async {
    if (phase != TrackingPhase.idle) return;
    phase = TrackingPhase.starting;
    error = null;
    notifyListeners();

    final access = await _locationService.ensureAccess();
    if (access != LocationAccess.granted) {
      gps = switch (access) {
        LocationAccess.deniedForever => GpsStatus.permissionDeniedForever,
        LocationAccess.serviceDisabled => GpsStatus.serviceDisabled,
        LocationAccess.unsupported => GpsStatus.unsupported,
        _ => GpsStatus.permissionDenied,
      };
      error = switch (access) {
        LocationAccess.deniedForever => 'Location permission is blocked. Allow it in the app settings.',
        LocationAccess.serviceDisabled => 'Location (GPS) is turned off on this phone.',
        LocationAccess.unsupported => 'Vehicle tracking is available in the Android app.',
        _ => 'Location permission is needed to share vehicle data.',
      };
      phase = TrackingPhase.idle;
      notifyListeners();
      return;
    }

    try {
      session = await _repo.startTracking(v.id);
    } on ApiException catch (e) {
      error = e.userMessage;
      phase = TrackingPhase.idle;
      notifyListeners();
      return;
    }

    await _telemetryQueue.dropOtherSessions(session!.id); // earlier sessions are closed; their packets cannot be delivered
    vehicle = v;
    _builder = PacketBuilder();
    _seq = 0;
    _failures = 0;
    _nextAttempt = null;
    sent = rejected = droppedOld = 0;
    lastRejectReason = null;
    localDistanceM = 0;
    lastFix = null;
    lastFixAt = null;
    emergencyActive = false;
    gps = GpsStatus.searching;
    link = LinkStatus.online;
    phase = TrackingPhase.active;
    notifyListeners();

    _fixSub = _locationService
        .fixes(
          notificationTitle: 'Smart Traffic: sharing vehicle data',
          notificationText: '${v.code} is sending location and speed to the traffic system. Open the app to stop.',
        )
        .listen(_onFix, onError: (Object e) {
      gps = GpsStatus.searching;
      notifyListeners();
    });
    _serviceSub = _locationService.serviceEnabledChanges().listen((enabled) {
      gps = enabled ? GpsStatus.searching : GpsStatus.serviceDisabled;
      notifyListeners();
    }, onError: (_) {});
    _uploadTimer = Timer.periodic(UploadPolicy.uploadInterval, (_) => uploadNow());
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkFixAge());
  }

  Future<void> _onFix(GpsFix fix) async {
    if (!isActive || session == null) return;
    final previous = lastFix;
    lastFix = fix;
    lastFixAt = _now();
    gps = switch (gpsQualityFor(fix.accuracyM)) {
      GpsQuality.excellent => GpsStatus.excellent,
      GpsQuality.good => GpsStatus.good,
      GpsQuality.fair => GpsStatus.fair,
      GpsQuality.poor => GpsStatus.poor,
    };
    final packet = _builder.build(fix, _seq, emergency: emergencyActive);
    if (packet != null) {
      if (previous != null && fix.accuracyM <= 25 && previous.accuracyM <= 25) {
        localDistanceM += PacketBuilder.distanceM(previous.lat, previous.lon, fix.lat, fix.lon);
      }
      await _telemetryQueue.add(session!.id, _seq, fix.time, packet);
      _seq++;
      queued++;
      if (queued > UploadPolicy.maxQueuedPackets) {
        droppedOld += await _telemetryQueue.trimTo(UploadPolicy.maxQueuedPackets);
        queued = await _telemetryQueue.count();
      }
    }
    notifyListeners();
  }

  void _checkFixAge() {
    if (!isActive) return;
    final at = lastFixAt;
    if (gps != GpsStatus.serviceDisabled &&
        (at == null || _now().difference(at) > UploadPolicy.noFixWarningAfter) &&
        gps != GpsStatus.searching) {
      gps = GpsStatus.searching;
      notifyListeners();
    }
  }

  /// Sends the oldest queued packets. Safe to call at any time; overlapping calls are ignored.
  Future<void> uploadNow({bool ignoreBackoff = false}) async {
    final current = session;
    final v = vehicle;
    if (_uploading || current == null || v == null) return;
    if (!ignoreBackoff && _nextAttempt != null && _now().isBefore(_nextAttempt!)) return;
    _uploading = true;
    try {
      droppedOld += await _telemetryQueue.dropOlderThan(_now().toUtc().subtract(UploadPolicy.maxPacketAge));
      final batch = await _telemetryQueue.oldest(current.id, UploadPolicy.batchSize);
      if (batch.isEmpty) return;
      try {
        final result = await _repo.upload(v.id, current.id, batch.map((q) => q.payload).toList());
        await _telemetryQueue.remove(batch.map((q) => q.id));
        sent += result.accepted;
        rejected += result.rejected;
        for (final r in result.results.where((r) => !r.accepted)) {
          lastRejectReason = r.reason;
        }
        emergencyActive = result.emergencyActive;
        link = LinkStatus.online;
        lastUploadAt = _now();
        _failures = 0;
        _nextAttempt = null;
      } on ApiException catch (e) {
        switch (UploadPolicy.classify(e)) {
          case UploadAction.retryLater:
            _failures++;
            link = e.isNetwork ? LinkStatus.offline : LinkStatus.degraded;
            _nextAttempt = _now().add(UploadPolicy.backoff(_failures));
          case UploadAction.dropBatch:
            await _telemetryQueue.remove(batch.map((q) => q.id));
            rejected += batch.length;
            lastRejectReason = e.code;
          case UploadAction.stopTracking:
            error = UploadPolicy.stopMessage(e);
            await _shutdown(callServer: false);
        }
      }
    } finally {
      _uploading = false;
      queued = await _telemetryQueue.count();
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (phase != TrackingPhase.active) return;
    phase = TrackingPhase.stopping;
    notifyListeners();
    await _shutdown(callServer: true);
  }

  Future<void> _shutdown({required bool callServer}) async {
    await _fixSub?.cancel();
    await _serviceSub?.cancel();
    _uploadTimer?.cancel();
    _watchdog?.cancel();
    _fixSub = null;
    _serviceSub = null;

    final current = session;
    final v = vehicle;
    if (callServer && current != null && v != null) {
      // Deliver what is queued before closing the session (a few batches at most).
      for (var i = 0; i < 3 && await _telemetryQueue.count() > 0 && link != LinkStatus.offline; i++) {
        final before = await _telemetryQueue.count();
        await uploadNow(ignoreBackoff: true);
        if (await _telemetryQueue.count() >= before) break;
      }
      try {
        await _repo.stopTracking(v.id, current.id);
      } on ApiException {
        // Offline: the server closes idle sessions on its own after a few minutes.
      }
    }
    if (current != null) await _telemetryQueue.dropOtherSessions('');
    queued = 0;
    session = null;
    emergencyActive = false;
    gps = GpsStatus.off;
    phase = TrackingPhase.idle;
    notifyListeners();
  }

  /// Called by the emergency screen after the server confirmed a change.
  void setEmergencyActive(bool value) {
    emergencyActive = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _fixSub?.cancel();
    _serviceSub?.cancel();
    _uploadTimer?.cancel();
    _watchdog?.cancel();
    super.dispose();
  }
}
