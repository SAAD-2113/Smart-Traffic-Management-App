import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/vehicle_repository.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/auth/login_screen.dart';
import '../../hardware/platform/hardware_platform.dart';
import '../../mode/switch_mode.dart';
import '../../services/location_service.dart';
import '../../widgets/common.dart';
import '../data/v2i_repository.dart';
import '../transport/cloud_relay.dart';
import '../transport/links.dart';
import 'digital_home.dart';

/// Creates the transports and the monotonic clock of the controllers. The app uses the cloud
/// relay and a Stopwatch; tests use the in-app loopback and the test clock.
class DigitalServices {
  DigitalServices(this._repo);
  final V2IRepository _repo;

  /// Signal timing uses this monotonic clock only, never the wall clock.
  v2i.MonoClock clock() => v2i.StopwatchClock();

  RelaySocket _socket(String sessionId) => RelaySocket(
        uri: _repo.relayUri(),
        sessionId: sessionId,
        accessToken: () => _repo.api.accessToken,
        refreshToken: _repo.api.refresh,
      );

  IntersectionLink intersection(String sessionId) => CloudIntersectionLink(_socket(sessionId));
  VehicleLink vehicle(String sessionId) => CloudVehicleLink(_socket(sessionId));
}

/// Digital V2I mode: sign in (the same accounts as the Software System), then this phone is
/// either an intersection (ADMIN / MANAGER) or a vehicle (driver), as the server decides.
class DigitalApp extends StatelessWidget {
  const DigitalApp({super.key, required this.config, required this.api});

  final AppConfig config;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: config),
        Provider.value(value: api),
        Provider(create: (_) => AuthRepository(api)),
        Provider(create: (_) => V2IRepository(api)),
        Provider(create: (_) => VehicleRepository(api)),
        Provider(create: (c) => DigitalServices(c.read<V2IRepository>())),
        Provider(create: (_) => LocationService()),
        Provider<HardwarePlatform>(create: (_) => const HardwarePlatform()),
        ChangeNotifierProvider(create: (c) => AuthController(c.read<AuthRepository>(), api)..init()),
      ],
      child: Consumer<AppConfig>(
        builder: (context, config, _) => MaterialApp(
          title: 'Digital V2I',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: config.themeMode,
          home: const DigitalGate(),
        ),
      ),
    );
  }
}

/// Signed out: the usual login. Signed in: the Digital V2I home for this account.
class DigitalGate extends StatelessWidget {
  const DigitalGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return switch (auth.status) {
      AuthStatus.unknown => const Scaffold(
          body: SafeArea(
            child: Stack(children: [
              LoadingView(label: 'Connecting…'),
              Positioned(top: 8, right: 8, child: SwitchModeButton()),
            ]),
          ),
        ),
      AuthStatus.signedOut => const LoginScreen(),
      AuthStatus.signedIn => DigitalHome(key: ValueKey('digital-${auth.user!.id}')),
    };
  }
}
