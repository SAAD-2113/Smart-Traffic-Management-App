import '../../core/network/api_client.dart';
import '../models/emergency.dart';
import '../models/json.dart';
import '../models/telemetry.dart';
import '../models/vehicle.dart';

/// Driver-side API: own vehicles, device binding, tracking, telemetry and emergency mode.
/// Calls that act for this phone send the installation id (X-Installation-Id).
class VehicleRepository {
  VehicleRepository(this._api);
  final ApiClient _api;

  String get installationId => _api.installationId;

  Future<List<OwnerVehicle>> myVehicles() async =>
      jsonList(await _api.get('/me/vehicles')).map(OwnerVehicle.fromJson).toList();

  Future<OwnerVehicle> register({required String type, required String displayName, String? registrationNumber}) async =>
      OwnerVehicle.fromJson(await _api.post('/vehicles', body: {
        'vehicleType': type,
        'displayName': displayName.trim(),
        if (registrationNumber != null && registrationNumber.trim().isNotEmpty)
          'registrationNumber': registrationNumber.trim(),
      }) as Json);

  Future<List<DeviceInfo>> devices(String vehicleId) async =>
      jsonList(await _api.get('/vehicles/$vehicleId/devices')).map(DeviceInfo.fromJson).toList();

  Future<void> bindThisDevice(String vehicleId, {required String platform, String? appVersion}) =>
      _api.post('/vehicles/$vehicleId/devices', body: {
        'installationId': installationId,
        'platform': platform,
        'appVersion': ?appVersion,
      });

  Future<TrackingSession> startTracking(String vehicleId) async =>
      TrackingSession.fromJson(await _api.post('/vehicles/$vehicleId/tracking/start', device: true, body: {}) as Json);

  Future<void> stopTracking(String vehicleId, String? sessionId) =>
      _api.post('/vehicles/$vehicleId/tracking/stop', body: {'sessionId': ?sessionId});

  Future<List<TrackingSession>> sessions(String vehicleId, {int limit = 30}) async =>
      jsonList(await _api.get('/vehicles/$vehicleId/tracking/sessions', query: {'limit': '$limit'}))
          .map(TrackingSession.fromJson)
          .toList();

  Future<TelemetryUploadResult> upload(String vehicleId, String sessionId, List<Json> packets) async =>
      TelemetryUploadResult.fromJson(await _api.post('/vehicles/$vehicleId/telemetry', device: true, body: {
        'sessionId': sessionId,
        'packets': packets,
      }) as Json);

  Future<EmergencyStatus> emergencyStatus(String vehicleId) async =>
      EmergencyStatus(await _api.get('/vehicles/$vehicleId/emergency') as Json);

  Future<EmergencyEvent> startEmergency(String vehicleId) async => EmergencyEvent(
      await _api.post('/vehicles/$vehicleId/emergency/start', device: true, body: {'confirm': true}) as Json);

  Future<void> stopEmergency(String vehicleId) => _api.post('/vehicles/$vehicleId/emergency/stop');

  Future<EmergencyStatus> requestAuthorization(String vehicleId) async =>
      EmergencyStatus(await _api.post('/vehicles/$vehicleId/emergency/authorization-request') as Json);
}
