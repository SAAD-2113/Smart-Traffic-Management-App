import 'json.dart';

enum UserRole { endUser, manager, admin }

UserRole parseRole(String value) => switch (value) {
      'MANAGER' => UserRole.manager,
      'ADMIN' => UserRole.admin,
      _ => UserRole.endUser,
    };

class AppUser {
  AppUser({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    this.phone,
  });

  factory AppUser.fromJson(Json j) => AppUser(
        id: j['id'] as String,
        email: j['email'] as String,
        fullName: j['fullName'] as String,
        role: parseRole(j['role'] as String),
        phone: j['phone'] as String?,
      );

  final String id;
  final String email;
  final String fullName;
  final UserRole role;
  final String? phone;

  bool get isManager => role == UserRole.manager || role == UserRole.admin;
  bool get isAdmin => role == UserRole.admin;

  String get roleLabel => switch (role) {
        UserRole.endUser => 'Driver',
        UserRole.manager => 'Traffic manager',
        UserRole.admin => 'Administrator',
      };
}
