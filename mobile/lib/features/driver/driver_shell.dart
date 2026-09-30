import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../widgets/common.dart';
import 'driver_controller.dart';
import 'emergency_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'trips_screen.dart';
import 'vehicle_setup_screen.dart';

/// Driver app: deliberately few screens and large controls (the user may be in a vehicle).
class DriverShell extends StatefulWidget {
  const DriverShell({super.key});

  @override
  State<DriverShell> createState() => _DriverShellState();
}

class _DriverShellState extends State<DriverShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final driver = context.watch<DriverController>();
    if (driver.loading) return const Scaffold(body: LoadingView(label: 'Loading your vehicle…'));
    if (driver.error != null && driver.vehicles.isEmpty) {
      return Scaffold(body: ErrorView(message: driver.error!, onRetry: driver.load));
    }
    if (driver.selected == null) return const VehicleSetupScreen(firstVehicle: true);

    final showEmergency = driver.selected!.isEmergencyVehicle;
    final pages = <Widget>[
      const HomeScreen(),
      const TripsScreen(),
      if (showEmergency) const EmergencyScreen(),
      const ProfileScreen(),
    ];
    final destinations = <NavigationDestination>[
      const NavigationDestination(icon: Icon(Icons.speed_outlined), selectedIcon: Icon(Icons.speed), label: 'Tracking'),
      const NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route), label: 'Trips'),
      if (showEmergency)
        const NavigationDestination(icon: Icon(Icons.emergency_outlined), selectedIcon: Icon(Icons.emergency), label: 'Emergency'),
      const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
    ];
    final index = _index.clamp(0, pages.length - 1);
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: destinations,
      ),
    );
  }
}
