import '../../core/network/api_client.dart';
import '../models/json.dart';
import '../models/user.dart';

class AuthRepository {
  AuthRepository(this._api);
  final ApiClient _api;

  Future<AppUser> login(String email, String password) async {
    final data = await _api.post('/auth/login', auth: false, body: {
      'email': email.trim(),
      'password': password,
      'installationId': _api.installationId,
    }) as Json;
    await _api.setSession(accessToken: data['accessToken'] as String, refreshToken: data['refreshToken'] as String);
    return AppUser.fromJson(data['user'] as Json);
  }

  Future<void> register({required String email, required String password, required String fullName, String? phone}) =>
      _api.post('/auth/register', auth: false, body: {
        'email': email.trim(),
        'password': password,
        'fullName': fullName.trim(),
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      });

  /// Restores a session from the stored refresh token. Returns null when signed out.
  Future<AppUser?> restore() async {
    if (!await _api.refresh()) return null;
    return me();
  }

  Future<AppUser> me() async => AppUser.fromJson(await _api.get('/me') as Json);

  Future<AppUser> updateProfile({String? fullName, String? phone}) async => AppUser.fromJson(await _api.patch('/me', body: {
        'fullName': ?fullName,
        'phone': (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
      }) as Json);

  Future<void> logout() async {
    final refreshToken = await _api.storedRefreshToken();
    try {
      if (refreshToken != null) await _api.post('/auth/logout', auth: false, body: {'refreshToken': refreshToken});
    } finally {
      await _api.clearSession();
    }
  }

  Future<String> forgotPassword(String email) async =>
      ((await _api.post('/auth/password/forgot', auth: false, body: {'email': email.trim()})) as Json)['message'] as String;

  Future<void> resetPassword(String token, String newPassword) =>
      _api.post('/auth/password/reset', auth: false, body: {'token': token.trim(), 'newPassword': newPassword});

  Future<void> changePassword(String current, String next) =>
      _api.post('/auth/password/change', body: {'currentPassword': current, 'newPassword': next});
}
