import '../../core/network/api_client.dart';
import '../models/emergency.dart';
import '../models/json.dart';
import '../models/signals.dart';
import '../models/telemetry.dart';
import '../models/traffic.dart';

/// Manager/admin API: monitoring, traffic, emergency review, signals, configuration, demo.
class ManagerRepository {
  ManagerRepository(this._api);
  final ApiClient _api;

  // -- monitoring -----------------------------------------------------------------
  Future<TrafficOverview> overview() async => TrafficOverview(await _api.get('/traffic/overview') as Json);

  Future<List<LiveVehicle>> liveVehicles({bool includeSimulated = true, bool onlyActive = true}) async =>
      jsonList(await _api.get('/manager/live/vehicles', query: {
        'includeSimulated': '$includeSimulated',
        'onlyActive': '$onlyActive',
      })).map(LiveVehicle.fromJson).toList();

  Future<LiveVehicle> liveVehicle(String id) async =>
      LiveVehicle.fromJson(await _api.get('/manager/live/vehicles/$id') as Json);

  Future<List<TrackPoint>> vehicleTrack(String id, {int minutes = 10}) async =>
      jsonList(await _api.get('/manager/vehicles/$id/telemetry', query: {'minutes': '$minutes', 'limit': '1200'}))
          .map(TrackPoint.fromJson)
          .toList();

  /// Registry view of a vehicle (status, type, emergency authorisation; no owner identity).
  Future<Json> managerVehicle(String id) async => await _api.get('/manager/vehicles/$id') as Json;

  Future<void> setVehicleStatus(String id, String status, String reason) =>
      _api.patch('/manager/vehicles/$id/status', body: {'status': status, 'reason': reason});

  Future<List<IntersectionTraffic>> trafficIntersections() async =>
      jsonList(await _api.get('/traffic/intersections')).map(IntersectionTraffic.new).toList();

  Future<HistorySeries> intersectionHistory(String id, {double hours = 1, int bucketS = 60}) async =>
      HistorySeries(await _api.get('/traffic/intersections/$id/history', query: {
        'hours': '$hours',
        'bucketS': '$bucketS',
      }) as Json);

  Future<List<HistorySeries>> networkHistory({double hours = 1, int bucketS = 60}) async =>
      jsonList(((await _api.get('/traffic/history', query: {'hours': '$hours', 'bucketS': '$bucketS'})) as Json)['series'])
          .map(HistorySeries.new)
          .toList();

  // -- emergency ------------------------------------------------------------------
  Future<List<ActiveEmergency>> activeEmergencies() async =>
      jsonList(await _api.get('/emergency/active')).map(ActiveEmergency.new).toList();

  Future<List<EmergencyEvent>> emergencyEvents({int limit = 100}) async =>
      jsonList(await _api.get('/manager/emergency/events', query: {'limit': '$limit'})).map(EmergencyEvent.new).toList();

  Future<void> endEmergency(String eventId, String note) =>
      _api.post('/manager/emergency/events/$eventId/end', body: {'note': note});

  Future<List<AuthorizationRequest>> authorizations({String? status}) async => jsonList(
          await _api.get('/manager/emergency/authorizations', query: {'status': ?status}))
      .map(AuthorizationRequest.new)
      .toList();

  Future<void> approve(String id, {DateTime? validUntil, String? notes}) =>
      _api.post('/manager/emergency/authorizations/$id/approve', body: {
        'validUntil': ?validUntil?.toUtc().toIso8601String(),
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      });

  Future<void> reject(String id, String notes) =>
      _api.post('/manager/emergency/authorizations/$id/reject', body: {'notes': notes});

  Future<void> revoke(String vehicleId, String notes) =>
      _api.post('/manager/vehicles/$vehicleId/emergency-authorization/revoke', body: {'notes': notes});

  // -- signals ----------------------------------------------------------------------
  Future<List<SignalOverviewItem>> signalsOverview() async =>
      jsonList(await _api.get('/signals/overview')).map(SignalOverviewItem.new).toList();

  Future<SignalPlanConfig> signalPlan(String intersectionId) async =>
      SignalPlanConfig(await _api.get('/intersections/$intersectionId/signal-plan') as Json);

  Future<SignalPlanConfig> saveSignalPlan(String intersectionId, SignalPlanConfig plan) async =>
      SignalPlanConfig(await _api.put('/intersections/$intersectionId/signal-plan', body: plan.toJson()) as Json);

  Future<List<SignalDecisionInfo>> decisions(String intersectionId, {int limit = 20}) async =>
      jsonList(await _api.get('/intersections/$intersectionId/signal-decisions', query: {'limit': '$limit'}))
          .map(SignalDecisionInfo.new)
          .toList();

  // -- intersection configuration ---------------------------------------------------
  Future<IntersectionConfig> intersection(String id) async =>
      IntersectionConfig(await _api.get('/intersections/$id') as Json);

  Future<void> updateIntersection(String id, Json changes) => _api.patch('/intersections/$id', body: changes);

  Future<IntersectionConfig> createIntersection(Json body) async =>
      IntersectionConfig(await _api.post('/intersections', body: body) as Json);

  Future<void> addApproach(String intersectionId, Json body) =>
      _api.post('/intersections/$intersectionId/approaches', body: body);

  Future<void> addLink(String fromId, Json body) => _api.post('/intersections/$fromId/links', body: body);

  // -- demo -------------------------------------------------------------------------------
  Future<DemoStatus> demoStatus() async => DemoStatus(await _api.get('/demo/status') as Json);

  Future<DemoStatus> startDemo({required int vehicles, required bool ambulance}) async => DemoStatus(
      await _api.post('/demo/start', body: {'vehicles': vehicles, 'includeEmergencyVehicle': ambulance}) as Json);

  Future<DemoStatus> stopDemo() async => DemoStatus(await _api.post('/demo/stop') as Json);
}
