import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_exception.dart';
import '../../features/auth/auth_controller.dart';
import '../../mode/switch_mode.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../data/v2i_models.dart';
import '../data/v2i_repository.dart';
import 'driver_home.dart';
import 'host_home.dart';

const digitalGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF120806), Color(0xFF7F1D1D), Color(0xFFC2410C)],
);

/// After sign-in: what this account is in Digital V2I comes from the server (/v2i/me).
class DigitalHome extends StatefulWidget {
  const DigitalHome({super.key});

  @override
  State<DigitalHome> createState() => _DigitalHomeState();
}

class _DigitalHomeState extends State<DigitalHome> {
  late Future<V2IMe> _me = context.read<V2IRepository>().me();

  void _reload() => setState(() { _me = context.read<V2IRepository>().me(); });

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return Scaffold(
      body: FutureBuilder<V2IMe>(
        future: _me,
        builder: (context, snap) {
          final me = snap.data;
          return ListView(padding: EdgeInsets.zero, children: [
            GradientHeader(
              title: 'Digital V2I',
              subtitle: me == null
                  ? auth.user?.fullName
                  : '${auth.user?.fullName ?? ''} · ${me.canHost ? 'intersection host' : 'vehicle ${me.vehicleId}'}',
              icon: Icons.phonelink_ring_outlined,
              gradient: digitalGradient,
              actions: [
                IconButton(
                  key: const ValueKey('sign-out'),
                  tooltip: 'Sign out',
                  onPressed: auth.logout,
                  icon: const Icon(Icons.logout, color: Colors.white),
                ),
              ],
              child: const Align(alignment: Alignment.centerLeft, child: SwitchModeButton(onDark: true)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: switch (snap.connectionState) {
                    ConnectionState.done when snap.hasError => ErrorView(
                        message: snap.error is ApiException ? (snap.error as ApiException).message : '${snap.error}',
                        onRetry: _reload,
                      ),
                    ConnectionState.done when me != null => me.canHost
                        ? HostHome(me: me)
                        : me.canDrive
                            ? DriverHome(me: me, onChanged: _reload)
                            : const EmptyState(icon: Icons.block, title: 'This account cannot use Digital V2I.'),
                    _ => const Padding(padding: EdgeInsets.all(40), child: LoadingView(label: 'Loading…')),
                  },
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
