import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/vehicle.dart';
import '../../services/tracking_controller.dart';
import '../../widgets/common.dart';
import 'driver_controller.dart';

/// Emergency mode for authorised ambulance, fire and police vehicles.
/// Activation needs a 2-second press-and-hold and a confirmation; the server re-checks
/// authorisation, an active tracking session and a recent GPS fix.
class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<DriverController>().refreshEmergency());
  }

  Future<void> _activate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.emergency, color: StatusColors.emergency, size: 40),
        title: const Text('Activate emergency mode?'),
        content: const Text('The traffic system and the traffic managers will be told this vehicle is on an '
            'emergency call. Use it only while responding to an emergency.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: StatusColors.emergency),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Activate'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final tracking = context.read<TrackingController>();
    final ok = await runGuarded(context, () => context.read<DriverController>().activateEmergency());
    if (ok) tracking.setEmergencyActive(true);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _deactivate() async {
    setState(() => _busy = true);
    final tracking = context.read<TrackingController>();
    final ok = await runGuarded(context, () => context.read<DriverController>().deactivateEmergency(),
        success: 'Emergency mode turned off.');
    if (ok) tracking.setEmergencyActive(false);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final driver = context.watch<DriverController>();
    final tracking = context.watch<TrackingController>();
    final status = driver.emergency;
    final theme = Theme.of(context);
    final active = status?.activeEvent != null || tracking.emergencyActive;

    return Scaffold(
      appBar: AppBar(title: const Text('Emergency mode')),
      body: RefreshIndicator(
        onRefresh: driver.refreshEmergency,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            color: active ? StatusColors.emergency : null,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Icon(Icons.emergency, size: 56, color: active ? Colors.white : StatusColors.neutral),
                const SizedBox(height: 8),
                Text('Emergency Mode',
                    style: theme.textTheme.titleMedium?.copyWith(color: active ? Colors.white : null)),
                Text(active ? 'ACTIVE' : 'OFF',
                    style: theme.textTheme.displaySmall
                        ?.copyWith(fontWeight: FontWeight.w900, color: active ? Colors.white : StatusColors.neutral)),
                if (active) ...[
                  const SizedBox(height: 8),
                  const Text('Traffic system has been notified.',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  if (status?.activeEvent != null)
                    Ticker(
                      builder: (_) => Text(
                        'Active for ${Units.duration(DateTime.now().difference(status!.activeEvent!.startedAt).inSeconds.toDouble())}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 16),
          if (status == null)
            const LoadingView()
          else if (!status.authorized) ...[
            _AuthorizationPanel(
              status: status.authorizationStatus,
              vehicleType: status.vehicleType,
              onRequest: () => runGuarded(context, driver.requestAuthorization, success: 'Request sent for review.'),
            ),
          ] else ...[
            if (!tracking.isActive && !active)
              const MessageBanner(
                icon: Icons.info_outline,
                color: StatusColors.info,
                text: 'Start tracking first: emergency priority needs the vehicle\'s live position.',
              ),
            const SizedBox(height: 12),
            if (active)
              SizedBox(
                height: 64,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _deactivate,
                  icon: const Icon(Icons.stop),
                  label: const Text('Turn off emergency mode', style: TextStyle(fontSize: 17)),
                ),
              )
            else
              HoldToConfirmButton(
                label: 'Hold to activate emergency mode',
                enabled: tracking.isActive && !_busy,
                onConfirmed: _activate,
              ),
            const SizedBox(height: 16),
            InfoRow('Authorisation', 'Approved'),
            InfoRow('Valid until', status.validUntil == null ? 'No expiry' : Units.dateTime(status.validUntil)),
            const SizedBox(height: 8),
            Text(
              'Emergency mode ends automatically if the vehicle stops sending data for 2 minutes, after '
              '60 minutes, when tracking stops, or if a traffic manager ends it. Signal priority is a '
              'simulation/prototype feature: real traffic signals are never controlled by this app.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}

class _AuthorizationPanel extends StatelessWidget {
  const _AuthorizationPanel({required this.status, required this.vehicleType, required this.onRequest});
  final String? status;
  final String vehicleType;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final (text, color, canRequest) = switch (status) {
      'PENDING' => ('Your ${vehicleTypeLabel(vehicleType).toLowerCase()} is waiting for verification by a traffic '
          'manager. Emergency mode becomes available once it is approved.', StatusColors.warning, false),
      'REJECTED' => ('The authorisation request was rejected. Contact the traffic management office, then request again.',
          StatusColors.danger, true),
      'REVOKED' => ('Emergency authorisation for this vehicle was revoked.', StatusColors.danger, true),
      'APPROVED' => ('The authorisation has expired. Request a new one.', StatusColors.warning, true),
      _ => ('This vehicle is not authorised for emergency mode.', StatusColors.neutral, true),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MessageBanner(icon: Icons.verified_user_outlined, color: color, text: text),
      if (canRequest) ...[
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRequest, child: const Text('Request authorisation')),
      ],
    ]);
  }
}
