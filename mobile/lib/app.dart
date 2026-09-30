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
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: config.themeMode,
          home: const _AuthGate(),
        ),
      ),
    );
  }
}

/// Chooses the driver or manager experience from the role the server returned.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    switch (auth.status) {
      case AuthStatus.unknown:
        return const Scaffold(body: LoadingView(label: 'Connecting…'));
      case AuthStatus.signedOut:
        return const LoginScreen();
      case AuthStatus.signedIn:
        final user = auth.user!;
        if (user.isManager) {
          return ChangeNotifierProvider(
            key: ValueKey('manager-${user.id}'),
            create: (c) => LiveController(c.read<ApiClient>(), c.read<ManagerRepository>())..start(),
            child: const ManagerShell(),
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
          child: const DriverShell(),
        );
    }
  }
}
