import 'dart:math' as math;

import '../core/network/api_exception.dart';

enum UploadAction {
  /// Keep the packets and try again later (offline, server busy, rate limited).
  retryLater,

  /// The server refuses this batch as malformed: drop it so it cannot block the queue.
  dropBatch,

  /// Tracking cannot continue (session closed, phone unbound, vehicle suspended).
  stopTracking,
}

/// Decisions about queued telemetry, kept free of I/O so they can be unit tested.
class UploadPolicy {
  static const uploadInterval = Duration(seconds: 2);
  static const batchSize = 100;
  static const maxQueuedPackets = 3600; // about one hour at 1 Hz
  /// The server accepts backfill up to 10 minutes old; stop a little earlier so packets
  /// are not sent only to be rejected.
  static const maxPacketAge = Duration(minutes: 9, seconds: 30);
  static const noFixWarningAfter = Duration(seconds: 10);

  static Duration backoff(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return Duration.zero;
    final seconds = math.min(30, math.pow(2, consecutiveFailures).toInt());
    return Duration(seconds: seconds);
  }

  static bool isTooOld(DateTime recordedAt, DateTime now) => now.difference(recordedAt) > maxPacketAge;

  static UploadAction classify(ApiException e) {
    if (e.isNetwork || e.isServerError || e.isRateLimited || e.isAuth) return UploadAction.retryLater;
    if (e.statusCode == 409 || e.statusCode == 404 || e.statusCode == 403) return UploadAction.stopTracking;
    if (e.statusCode == 422 || e.statusCode == 400) return UploadAction.dropBatch;
    return UploadAction.retryLater;
  }

  static String stopMessage(ApiException e) => switch (e.code) {
        'SESSION_NOT_ACTIVE' => 'The tracking session was closed by the server. Start tracking again.',
        'DEVICE_NOT_BOUND' => 'This phone is no longer linked to the vehicle. Link it again in Profile.',
        'VEHICLE_NOT_ACTIVE' => 'This vehicle has been suspended by the traffic manager.',
        _ => e.message,
      };
}
