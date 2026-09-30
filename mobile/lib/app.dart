import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/theme/app_theme.dart';
import 'data/local/telemetry_queue.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/manager_repository.dart';
import 'data/repositories/vehicle_repository.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_screen.dart';
import 'features/driver/driver_controller.dart';
import 'features/driver/driver_shell.dart';
import 'features/manager/live_controller.dart';
import 'features/manager/manager_shell.dart';
import 'services/location_service.dart';
import 'services/tracking_controller.dart';
import 'widgets/common.dart';

class SmartTrafficApp extends StatelessWidget {
  const SmartTrafficApp({super.key, required this.config, required this.api, required this.queue});

  final AppConfig config;
  final ApiClient api;
  final TelemetryQueue queue;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: config),
        Provider.value(value: api),
        Provider<TelemetryQueue>.value(value: queue),
        Provider(create: (_) => AuthRepository(api)),
        Provider(create: (_) => VehicleRepository(api)),
        Provider(create: (_) => ManagerRepository(api)),
        Provider(create: (_) => LocationService()),
        ChangeNotifierProvider(create: (c) => AuthController(c.read<AuthRepository>(), api)..init()),
      ],
      child: Consumer<AppConfig>(
        builder: (context, config, _) => MaterialApp(
          title: 'Smart Traffic',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: config.themeMode,
          // Role controllers sit above the navigator so every pushed screen can reach them.
          builder: (context, child) => _SessionScope(child: child!),
          home: const _AuthGate(),
        ),
      ),
    );
  }
}

final _navigatorKey = GlobalKey<NavigatorState>();

/// Provides the controllers of the signed-in role. Recreated when the user changes.
class _SessionScope extends StatelessWidget {
  const _SessionScope({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final user = auth.user;
    if (auth.status != AuthStatus.signedIn || user == null) return child;
    if (user.isManager) {
      return ChangeNotifierProvider(
        key: ValueKey('manager-${user.id}'),
        create: (c) => LiveController(c.read<ApiClient>(), c.read<ManagerRepository>())..start(),
        child: child,
      );
    }
    return MultiProvider(
      key: ValueKey('driver-${user.id}'),
      providers: [
        ChangeNotifierProvider(create: (c) => DriverController(c.read<VehicleRepository>(), c.read<AppConfig>())..load()),
        ChangeNotifierProvider(
          create: (c) => TrackingController(
            repository: c.read<VehicleRepository>(),
            location: c.read<LocationService>(),
            queue: c.read<TelemetryQueue>(),
          ),
        ),
      ],
      child: child,
    );
  }
}

/// Chooses the driver or manager experience from the role the server returned.
AuthStatus? _lastStatus;

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    // Screens pushed during a session must not outlive it (their controllers are gone).
    if (_lastStatus == AuthStatus.signedIn && auth.status != AuthStatus.signedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigatorKey.currentState?.popUntil((r) => r.isFirst));
    }
    _lastStatus = auth.status;
    switch (auth.status) {
      case AuthStatus.unknown:
        return const Scaffold(body: LoadingView(label: 'Connecting…'));
      case AuthStatus.signedOut:
        return const LoginScreen();
      case AuthStatus.signedIn:
        return auth.user!.isManager ? const ManagerShell() : const DriverShell();
    }
  }
}
