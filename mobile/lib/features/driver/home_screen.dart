import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../services/location_service.dart';
import '../../services/tracking_controller.dart';
import '../../widgets/brand.dart';
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
          _TrackingHero(tracking: tracking),
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

/// Tracking status and speed on a gradient card: green-teal while tracking, navy when off.
class _TrackingHero extends StatelessWidget {
  const _TrackingHero({required this.tracking});
  final TrackingController tracking;

  static const _activeGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF065F46), Color(0xFF0F766E), Color(0xFF0E7490)],
  );

  @override
  Widget build(BuildContext context) {
    final active = tracking.isActive;
    final session = tracking.session;
    final speed = active ? tracking.speedMps : null;
    final status = switch (tracking.phase) {
      TrackingPhase.active => 'Tracking active',
      TrackingPhase.starting => 'Starting…',
      TrackingPhase.stopping => 'Stopping…',
      TrackingPhase.idle => 'Tracking off',
    };
    return Container(
      decoration: BoxDecoration(
        gradient: active ? _activeGradient : Brand.hero,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Brand.navy.withValues(alpha: 0.25), blurRadius: 16, offset: const Offset(0, 6))],
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: active ? SignalColors.green : Colors.white54,
              shape: BoxShape.circle,
              boxShadow: active ? [BoxShadow(color: SignalColors.green.withValues(alpha: 0.9), blurRadius: 8)] : null,
            ),
          ),
          const SizedBox(width: 10),
          Text(status, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (session != null)
            Ticker(
              builder: (_) => Text(
                Units.duration(DateTime.now().difference(session.startedAt).inSeconds.toDouble()),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontWeight: FontWeight.w700),
              ),
            ),
        ]),
        if (session != null)
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 2),
            child: Text('Since ${Units.clock(session.startedAt)}',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
          ),
        const SizedBox(height: 14),
        Center(
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(speed == null ? '—' : Units.speedValue(speed),
                style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.w800, height: 1.0)),
            const SizedBox(width: 8),
            Text('km/h', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 20, fontWeight: FontWeight.w600)),
          ]),
        ),
        Center(
          child: Text(active ? 'Current speed' : 'Start tracking to share your position with the traffic system',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
        ),
      ]),
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
      return GradientButton(
        label: 'Stop tracking',
        icon: Icons.stop_circle_outlined,
        height: 64,
        busy: tracking.phase == TrackingPhase.stopping,
        gradient: const LinearGradient(colors: [Color(0xFFB91C1C), Color(0xFFEF4444)]),
        onPressed: tracking.isBusy ? null : tracking.stop,
      );
    }
    return GradientButton(
      label: 'Start tracking',
      icon: Icons.play_circle_outline,
      height: 64,
      busy: tracking.phase == TrackingPhase.starting,
      gradient: const LinearGradient(colors: [Color(0xFF047857), Color(0xFF10B981)]),
      onPressed: !enabled || tracking.isBusy ? null : () => tracking.start(driver.selected!),
    );
  }
}
