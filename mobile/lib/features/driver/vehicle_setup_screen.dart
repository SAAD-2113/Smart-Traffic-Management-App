import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/validators.dart';
import '../../data/models/vehicle.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import 'driver_controller.dart';

/// Registers a vehicle. The server assigns its Vehicle ID (VH-xxxx / EV-xxxx).
/// Choosing an emergency type only *requests* emergency authorisation.
class VehicleSetupScreen extends StatefulWidget {
  const VehicleSetupScreen({super.key, this.firstVehicle = false});
  final bool firstVehicle;

  @override
  State<VehicleSetupScreen> createState() => _VehicleSetupScreenState();
}

class _VehicleSetupScreenState extends State<VehicleSetupScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _registration = TextEditingController();
  String _type = 'NORMAL';
  bool _busy = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await runGuarded(context, () async {
      final v = await context.read<DriverController>().registerVehicle(
            type: _type,
            displayName: _name.text,
            registrationNumber: isEmergencyType(_type) ? _registration.text.toUpperCase().replaceAll(' ', '') : null,
          );
      if (mounted) showInfo(context, 'Vehicle registered as ${v.code}. This phone now reports for it.');
    });
    if (mounted) setState(() => _busy = false);
    if (ok && mounted && !widget.firstVehicle) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.firstVehicle ? 'Register your vehicle' : 'Add a vehicle'),
        actions: [
          if (widget.firstVehicle)
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: () => context.read<AuthController>().logout(),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Each participating vehicle gets its own Vehicle ID. The ID belongs to the vehicle, '
                      'so you can change phones later without changing it.'),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: _type,
                    decoration: const InputDecoration(labelText: 'Vehicle type', prefixIcon: Icon(Icons.directions_car)),
                    items: [for (final t in vehicleTypes) DropdownMenuItem(value: t, child: Text(vehicleTypeLabel(t)))],
                    onChanged: (v) => setState(() => _type = v ?? 'NORMAL'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    maxLength: 60,
                    decoration: const InputDecoration(
                        labelText: 'Name for this vehicle', hintText: 'e.g. My car', prefixIcon: Icon(Icons.label_outline)),
                    validator: (v) => Validators.required(v, 'A name'),
                  ),
                  if (isEmergencyType(_type)) ...[
                    const SizedBox(height: 4),
                    TextFormField(
                      controller: _registration,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Registration number', prefixIcon: Icon(Icons.badge_outlined)),
                      validator: Validators.registrationNumber,
                    ),
                    const SizedBox(height: 12),
                    const MessageBanner(
                      icon: Icons.verified_user,
                      color: StatusColors.info,
                      text: 'Emergency vehicles must be verified. A traffic manager checks the registration '
                          'number before emergency mode can be used. Until then the vehicle reports as a normal vehicle.',
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Register vehicle'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
