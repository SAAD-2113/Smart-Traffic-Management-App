import '../../core/network/api_client.dart';
import '../../data/models/json.dart';
import 'v2i_models.dart';

/// Digital V2I REST calls. Every permission is checked by the server.
class V2IRepository {
  V2IRepository(this._api);
  final ApiClient _api;

  ApiClient get api => _api;

  Future<V2IMe> me() async => V2IMe.fromJson(await _api.get('/v2i/me') as Json);

  Future<V2IMe> requestEmergency(String reason) async =>
      V2IMe.fromJson(await _api.post('/v2i/me/emergency-request', body: {'reason': reason}) as Json);

  // host (ADMIN / MANAGER)
  Future<HostedSession> createSession({required String name, required double centerLat, required double centerLon}) async =>
      HostedSession.fromJson(
          await _api.post('/v2i/sessions', body: {'name': name, 'centerLat': centerLat, 'centerLon': centerLon}) as Json);

  Future<List<HostedSession>> mySessions() async =>
      jsonList(await _api.get('/v2i/sessions/mine')).map(HostedSession.fromJson).toList();

  Future<HostedSession> session(String id) async => HostedSession.fromJson(await _api.get('/v2i/sessions/$id') as Json);

  Future<HostedSession> closeSession(String id) async =>
      HostedSession.fromJson(await _api.post('/v2i/sessions/$id/close') as Json);

  /// Server copy of an export file (host / admin).
  Future<void> uploadExport(String sessionId, {required String filename, required String contentType, required String content}) =>
      _api.post('/v2i/sessions/$sessionId/exports', body: {'filename': filename, 'contentType': contentType, 'content': content});

  // admin: emergency authorisation
  Future<List<V2IProfileRow>> profiles({String? emergencyStatus}) async => jsonList(
          await _api.get('/v2i/profiles', query: emergencyStatus == null ? null : {'emergencyStatus': emergencyStatus}))
      .map(V2IProfileRow.fromJson)
      .toList();

  Future<V2IProfileRow> setEmergency(String email, String status) async =>
      V2IProfileRow.fromJson(await _api.put('/v2i/profiles/emergency', body: {'email': email, 'status': status}) as Json);

  // driver (END_USER)
  Future<JoinedSession> join(String code) async =>
      JoinedSession.fromJson(await _api.post('/v2i/join', body: {'joinCode': code.trim().toUpperCase()}) as Json);

  Future<List<JoinedSession>> joined() async => jsonList(await _api.get('/v2i/joined')).map(JoinedSession.fromJson).toList();

  Future<List<TripPoint>> tripPoints(String vehicleId, String sessionId) async =>
      jsonList(await _api.get('/vehicles/$vehicleId/tracking/sessions/$sessionId/points')).map(TripPoint.fromJson).toList();

  /// `ws(s)://<server>/api/v1/v2i/ws`
  Uri relayUri() {
    final base = Uri.parse(_api.baseUrl);
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '${base.path}/v2i/ws');
  }
}
