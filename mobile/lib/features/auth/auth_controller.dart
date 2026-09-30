import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../data/models/user.dart';
import '../../data/repositories/auth_repository.dart';

enum AuthStatus { unknown, signedOut, signedIn }

/// Who is signed in. The role comes from the server; the app never decides it.
class AuthController extends ChangeNotifier {
  AuthController(this._repo, ApiClient api) {
    api.onSessionExpired = _onSessionExpired;
  }

  final AuthRepository _repo;
  AuthStatus status = AuthStatus.unknown;
  AppUser? user;
  String? notice; // shown on the login screen (e.g. "session expired", "server unreachable")

  Future<void> init() async {
    try {
      final restored = await _repo.restore();
      user = restored;
      status = restored == null ? AuthStatus.signedOut : AuthStatus.signedIn;
    } on ApiException catch (e) {
      status = AuthStatus.signedOut;
      notice = e.isNetwork ? 'Could not reach the server. Check the server address and try again.' : e.message;
    }
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    user = await _repo.login(email, password);
    notice = null;
    status = AuthStatus.signedIn;
    notifyListeners();
  }

  Future<void> register({required String email, required String password, required String fullName, String? phone}) =>
      _repo.register(email: email, password: password, fullName: fullName, phone: phone);

  Future<void> refreshUser() async {
    user = await _repo.me();
    notifyListeners();
  }

  Future<void> updateProfile({String? fullName, String? phone}) async {
    user = await _repo.updateProfile(fullName: fullName, phone: phone);
    notifyListeners();
  }

  Future<void> changePassword(String current, String next) => _repo.changePassword(current, next);
  Future<String> forgotPassword(String email) => _repo.forgotPassword(email);
  Future<void> resetPassword(String token, String password) => _repo.resetPassword(token, password);

  Future<void> logout() async {
    try {
      await _repo.logout();
    } on ApiException {
      // Offline logout still clears the local session.
    }
    user = null;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  void _onSessionExpired() {
    if (status != AuthStatus.signedIn) return;
    user = null;
    status = AuthStatus.signedOut;
    notice = 'Your session has ended. Please sign in again.';
    notifyListeners();
  }
}
