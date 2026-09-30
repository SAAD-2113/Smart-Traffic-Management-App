import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/token_store.dart';
import '../config/app_config.dart';
import 'api_exception.dart';

/// Thin JSON-over-HTTPS client for the backend.
///
/// - adds the bearer access token;
/// - on an expired or invalid access token, refreshes once (single flight) and retries;
/// - converts every failure into an [ApiException] with the backend's error code.
class ApiClient {
  ApiClient(this._config, this._tokens, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  /// Long enough for a sleeping free-tier cloud server to wake up on the first request.
  static const requestTimeout = Duration(seconds: 60);

  final AppConfig _config;
  final TokenStore _tokens;
  final http.Client _http;

  String? _accessToken;
  Future<bool>? _refreshing;

  /// Called when the session can no longer be refreshed (logged out elsewhere, disabled…).
  void Function()? onSessionExpired;

  String? get accessToken => _accessToken;
  String get installationId => _config.installationId;
  String get baseUrl => _config.apiBaseUrl;

  Future<void> setSession({required String accessToken, required String refreshToken}) async {
    _accessToken = accessToken;
    await _tokens.writeRefreshToken(refreshToken);
  }

  Future<void> clearSession() async {
    _accessToken = null;
    await _tokens.clear();
  }

  Future<String?> storedRefreshToken() => _tokens.readRefreshToken();

  // -- public verbs --------------------------------------------------------------
  Future<dynamic> get(String path, {Map<String, String>? query, bool device = false}) =>
      _send('GET', path, query: query, device: device);

  Future<dynamic> post(String path, {Object? body, bool device = false, bool auth = true}) =>
      _send('POST', path, body: body, device: device, auth: auth);

  Future<dynamic> patch(String path, {Object? body}) => _send('PATCH', path, body: body);

  Future<dynamic> put(String path, {Object? body}) => _send('PUT', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Exchanges the stored refresh token for a new pair. Returns false when not possible.
  Future<bool> refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final refreshToken = await _tokens.readRefreshToken();
    if (refreshToken == null) return false;
    try {
      final data = await _send('POST', '/auth/refresh', body: {'refreshToken': refreshToken}, auth: false, retry: false)
          as Map<String, dynamic>;
      await setSession(accessToken: data['accessToken'] as String, refreshToken: data['refreshToken'] as String);
      return true;
    } on ApiException catch (e) {
      if (e.isNetwork || e.isServerError || e.isRateLimited) rethrow; // keep the session, try later
      await clearSession();
      return false;
    }
  }

  // -- core ------------------------------------------------------------------------
  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
    bool device = false,
    bool retry = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (auth && _accessToken != null) headers['Authorization'] = 'Bearer $_accessToken';
    if (device) headers['X-Installation-Id'] = installationId;

    http.Response response;
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _http.send(request).timeout(requestTimeout);
      response = await http.Response.fromStream(streamed).timeout(requestTimeout);
    } catch (e) {
      throw ApiException.network(e);
    }

    if (response.statusCode == 401 && auth && retry) {
      final code = _errorCode(response);
      if (code == 'TOKEN_EXPIRED' || code == 'INVALID_TOKEN' || code == 'NOT_AUTHENTICATED') {
        bool refreshed;
        try {
          refreshed = await refresh();
        } on ApiException {
          rethrow;
        }
        if (refreshed) {
          return _send(method, path, query: query, body: body, auth: auth, device: device, retry: false);
        }
        onSessionExpired?.call();
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.statusCode == 204 || response.body.isEmpty) return null;
      return jsonDecode(utf8.decode(response.bodyBytes));
    }
    throw _toException(response);
  }

  static String? _errorCode(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return (data['error'] as Map<String, dynamic>?)?['code'] as String?;
    } catch (_) {
      return null;
    }
  }

  static ApiException _toException(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final error = data['error'] as Map<String, dynamic>;
      return ApiException(
        statusCode: response.statusCode,
        code: error['code'] as String? ?? 'HTTP_ERROR',
        message: error['message'] as String? ?? 'Request failed.',
        details: ((error['details'] as List?) ?? []).whereType<Map<String, dynamic>>().toList(),
      );
    } catch (_) {
      return ApiException(
        statusCode: response.statusCode,
        code: 'HTTP_${response.statusCode}',
        message: 'The server returned an unexpected response (${response.statusCode}).',
      );
    }
  }

  /// WebSocket address of the live channel, derived from the server address.
  Uri liveSocketUri() {
    final base = Uri.parse(baseUrl);
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '${base.path}/live/ws');
  }
}
