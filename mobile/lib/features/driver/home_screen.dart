import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../services/location_service.dart';
import '../../services/tracking_controller.dart';
import '../../widgets/common.dart';
import 'driver_controller.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final driver = context.watch<DriverController>();
    final tracking = context.watch<TrackingController>();
    final vehicle = driver.selected!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Vehicle ${vehicle.code}', style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(vehicle.displayName, style: theme.textTheme.bodySmall),
        ]),
        actions: [
          if (tracking.emergencyActive)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: StatusChip(label: 'EMERGENCY', color: StatusColors.emergency, filled: true, icon: Icons.emergency),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (!vehicle.isActive)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: MessageBanner(
                icon: Icons.block,
                color: StatusColors.danger,
                text: 'This vehicle is suspended by the traffic manager and cannot send data.',
              ),
            ),
          if (!driver.phoneLinked) _LinkPhoneBanner(otherPhone: driver.otherPhoneLinked),
          _TrackingHeader(tracking: tracking),
          const SizedBox(height: 12),
          _SpeedCard(tracking: tracking),
          const SizedBox(height: 12),
          GridView(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 300,
              mainAxisExtent: 118,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _gpsCard(tracking),
              _connectionCard(tracking),
              _emergencyCard(tracking, vehicle.isEmergencyVehicle, driver.emergency?.authorized ?? false),
              MetricCard(
                label: 'Packets sent',
                value: '${tracking.sent}',
                icon: Icons.upload,
                caption: tracking.rejected > 0
                    ? '${tracking.rejected} rejected${tracking.lastRejectReason != null ? ' (${tracking.lastRejectReason})' : ''}'
                    : 'Last upload ${Units.ago(tracking.lastUploadAt)}',
              ),
            ],
          ),
          if (tracking.lastFix != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(children: [
                  InfoRow('Latitude', Units.coordinate(tracking.lastFix!.lat)),
                  InfoRow('Longitude', Units.coordinate(tracking.lastFix!.lon)),
                  InfoRow('Heading', Units.heading(tracking.lastFix!.headingDeg)),
                  InfoRow('GPS accuracy', '± ${tracking.lastFix!.accuracyM.toStringAsFixed(0)} m'),
                  InfoRow('Trip distance', Units.distance(tracking.localDistanceM)),
                ]),
              ),
            ),
          ],
          if (tracking.error != null) ...[
            const SizedBox(height: 12),
            MessageBanner(icon: Icons.error_outline, color: StatusColors.danger, text: tracking.error!),
            if (tracking.gps == GpsStatus.permissionDeniedForever || tracking.gps == GpsStatus.serviceDisabled)
              TextButton.icon(
                onPressed: () => tracking.gps == GpsStatus.serviceDisabled
                    ? context.read<LocationService>().openLocationSettings()
                    : context.read<LocationService>().openAppSettings(),
                icon: const Icon(Icons.settings),
                label: const Text('Open settings'),
              ),
          ],
          const SizedBox(height: 16),
          _StartStopButton(enabled: driver.phoneLinked && vehicle.isActive),
          const SizedBox(height: 12),
          Text(
            'While tracking is on, only the vehicle ID, position, speed, heading and time are shared, '
            'for traffic analysis. Tracking continues with the screen off; a notification shows it is running.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }

  Widget _gpsCard(TrackingController t) {
    final (label, color) = switch (t.gps) {
      GpsStatus.excellent => ('Excellent', StatusColors.ok),
      GpsStatus.good => ('Good', StatusColors.ok),
      GpsStatus.fair => ('Fair', StatusColors.warning),
      GpsStatus.poor => ('Poor', StatusColors.danger),
      GpsStatus.searching => ('Searching…', StatusColors.warning),
      GpsStatus.serviceDisabled => ('GPS off', StatusColors.danger),
      GpsStatus.permissionDenied || GpsStatus.permissionDeniedForever => ('No permission', StatusColors.danger),
      GpsStatus.unsupported => ('Not available', StatusColors.neutral),
      GpsStatus.off => ('Idle', StatusColors.neutral),
    };
    return MetricCard(
      label: 'GPS',
      value: label,
      icon: Icons.gps_fixed,
      color: color,
      caption: t.lastFix == null ? 'No fix yet' : '± ${t.lastFix!.accuracyM.toStringAsFixed(0)} m, ${Units.ago(t.lastFixAt)}',
    );
  }

  Widget _connectionCard(TrackingController t) {
    final (label, color) = switch (t.link) {
      LinkStatus.online => ('Online', StatusColors.ok),
      LinkStatus.offline => ('Offline', StatusColors.danger),
      LinkStatus.degraded => ('Server busy', StatusColors.warning),
      LinkStatus.unknown => ('—', StatusColors.neutral),
    };
    return MetricCard(
      label: 'Connection',
      value: t.isActive ? label : 'Idle',
      icon: Icons.cloud_outlined,
      color: t.isActive ? color : StatusColors.neutral,
      caption: t.queued > 0 ? '${t.queued} waiting to send' : 'Nothing waiting',
    );
  }

  Widget _emergencyCard(TrackingController t, bool eligible, bool authorized) => MetricCard(
        label: 'Emergency mode',
        value: t.emergencyActive ? 'ACTIVE' : 'OFF',
        icon: Icons.emergency_outlined,
        color: t.emergencyActive ? StatusColors.emergency : StatusColors.neutral,
        caption: !eligible ? 'Not an emergency vehicle' : (authorized ? 'Authorised' : 'Not authorised'),
      );
}

class _LinkPhoneBanner extends StatelessWidget {
  const _LinkPhoneBanner({required this.otherPhone});
  final bool otherPhone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(otherPhone ? 'Another phone reports for this vehicle' : 'This phone is not linked yet',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(otherPhone
                ? 'Linking this phone stops the other phone from sending data for this vehicle.'
                : 'Link this phone to send data for the vehicle.'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => runGuarded(context, () => context.read<DriverController>().linkThisPhone(),
                  success: 'This phone now reports for the vehicle.'),
              child: const Text('Use this phone'),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TrackingHeader extends StatelessWidget {
  const _TrackingHeader({required this.tracking});
  final TrackingController tracking;

  @override
  Widget build(BuildContext context) {
    final active = tracking.isActive;
    final color = active ? StatusColors.ok : StatusColors.neutral;
    final session = tracking.session;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                switch (tracking.phase) {
                  TrackingPhase.active => 'Tracking active',
                  TrackingPhase.starting => 'Starting…',
                  TrackingPhase.stopping => 'Stopping…',
                  TrackingPhase.idle => 'Tracking off',
                },
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (session != null)
                Ticker(
                  builder: (_) => Text(
                      'Since ${Units.clock(session.startedAt)} · ${Units.duration(DateTime.now().difference(session.startedAt).inSeconds.toDouble())}'),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _SpeedCard extends StatelessWidget {
  const _SpeedCard({required this.tracking});
  final TrackingController tracking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speed = tracking.isActive ? tracking.speedMps : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(children: [
          Text('Speed', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(speed == null ? '—' : Units.speedValue(speed),
                style: theme.textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Text('km/h', style: theme.textTheme.titleLarge),
          ]),
        ]),
      ),
    );
  }
}

class _StartStopButton extends StatelessWidget {
  const _StartStopButton({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tracking = context.watch<TrackingController>();
    final driver = context.read<DriverController>();
    if (tracking.isActive || tracking.phase == TrackingPhase.stopping) {
      return SizedBox(
        height: 64,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: StatusColors.danger),
          onPressed: tracking.isBusy ? null : tracking.stop,
          icon: const Icon(Icons.stop_circle_outlined, size: 28),
          label: const Text('Stop tracking', style: TextStyle(fontSize: 18)),
        ),
      );
    }
    return SizedBox(
      height: 64,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: StatusColors.ok),
        onPressed: !enabled || tracking.isBusy ? null : () => tracking.start(driver.selected!),
        icon: tracking.phase == TrackingPhase.starting
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
            : const Icon(Icons.play_circle_outline, size: 28),
        label: const Text('Start tracking', style: TextStyle(fontSize: 18)),
      ),
    );
  }
}
