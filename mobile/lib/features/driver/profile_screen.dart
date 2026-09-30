import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/validators.dart';
import '../../data/models/vehicle.dart';
import '../../services/tracking_controller.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import '../auth/server_settings_sheet.dart';
import 'driver_controller.dart';
import 'vehicle_setup_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final driver = context.watch<DriverController>();
    final tracking = context.watch<TrackingController>();
    final config = context.watch<AppConfig>();
    final user = auth.user!;
    final vehicle = driver.selected!;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const SectionHeader('Account'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(user.fullName),
              subtitle: Text('${user.email}\n${user.roleLabel}'),
              isThreeLine: true,
              trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _editProfile(context)),
            ),
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: const Text('Phone'),
              subtitle: Text(user.phone ?? 'Not set'),
            ),
            ListTile(
              leading: const Icon(Icons.password),
              title: const Text('Change password'),
              onTap: () => _changePassword(context),
            ),
          ]),
        ),
        const SectionHeader('Vehicle'),
        Card(
          child: Column(children: [
            InfoTile('Vehicle ID', vehicle.code, icon: Icons.badge),
            InfoTile('Name', vehicle.displayName, icon: Icons.label_outline),
            InfoTile('Type', vehicleTypeLabel(vehicle.vehicleType), icon: Icons.directions_car),
            if (vehicle.registrationNumber != null)
              InfoTile('Registration', vehicle.registrationNumber!, icon: Icons.confirmation_number_outlined),
            InfoTile('Status', vehicle.status, icon: Icons.verified_outlined),
            if (vehicle.isEmergencyVehicle)
              InfoTile('Emergency authorisation', vehicle.emergencyAuthorized ? 'Approved' : (vehicle.authorizationStatus ?? 'None'),
                  icon: Icons.emergency_outlined),
            InfoTile('This phone', driver.phoneLinked ? 'Linked (reports for this vehicle)' : 'Not linked',
                icon: Icons.phone_android),
          ]),
        ),
        if (driver.vehicles.length > 1) ...[
          const SectionHeader('Switch vehicle'),
          Card(
            child: RadioGroup<String>(
              groupValue: vehicle.id,
              onChanged: (id) {
                if (tracking.isActive) {
                  showInfo(context, 'Stop tracking before switching vehicle.');
                  return;
                }
                final v = driver.vehicles.firstWhere((v) => v.id == id);
                runGuarded(context, () => driver.select(v));
              },
              child: Column(children: [
                for (final v in driver.vehicles)
                  RadioListTile<String>(
                    value: v.id,
                    title: Text('${v.code} · ${v.displayName}'),
                    subtitle: Text(vehicleTypeLabel(v.vehicleType)),
                  ),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: tracking.isActive
              ? null
              : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VehicleSetupScreen())),
          icon: const Icon(Icons.add),
          label: const Text('Add another vehicle'),
        ),
        const SectionHeader('App'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server'),
              subtitle: Text(config.serverUrl),
              onTap: tracking.isActive ? null : () => showServerSettings(context),
            ),
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('Installation ID'),
              subtitle: Text(config.installationId),
            ),
            const ListTile(
              leading: Icon(Icons.privacy_tip_outlined),
              title: Text('Privacy'),
              subtitle: Text('Location is collected only while tracking is on. Managers see the vehicle ID, not your '
                  'name. Raw location history is deleted after 30 days.'),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(foregroundColor: StatusColors.danger),
          onPressed: () async {
            if (tracking.isActive) await tracking.stop();
            if (context.mounted) await context.read<AuthController>().logout();
          },
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ]),
    );
  }

  Future<void> _editProfile(BuildContext context) async {
    final auth = context.read<AuthController>();
    final name = TextEditingController(text: auth.user!.fullName);
    final phone = TextEditingController(text: auth.user!.phone ?? '');
    final form = GlobalKey<FormState>();
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit profile'),
        content: Form(
          key: form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Full name'), validator: Validators.name),
            const SizedBox(height: 12),
            TextFormField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'Phone', hintText: '+923001234567'),
                validator: Validators.optionalPhone),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              final ok = await runGuarded(dialogContext, () => auth.updateProfile(fullName: name.text.trim(), phone: phone.text));
              if (ok && dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

Future<void> _changePassword(BuildContext context) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final form = GlobalKey<FormState>();
  await showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Change password'),
      content: Form(
        key: form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: current,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Current password'),
            validator: (v) => Validators.required(v, 'Current password'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: next,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password'),
            validator: Validators.password,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            if (!form.currentState!.validate()) return;
            final ok = await runGuarded(dialogContext,
                () => dialogContext.read<AuthController>().changePassword(current.text, next.text),
                success: 'Password changed. Other devices were signed out.');
            if (ok && dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: const Text('Change'),
        ),
      ],
    ),
  );
}

Future<void> showChangePassword(BuildContext context) => _changePassword(context);

class InfoTile extends StatelessWidget {
  const InfoTile(this.label, this.value, {super.key, this.icon});
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: icon == null ? null : Icon(icon),
        title: Text(label),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      );
}
