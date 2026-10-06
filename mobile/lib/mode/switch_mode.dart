import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/tracking_controller.dart';
import 'app_mode.dart';

/// Returns to the mode selection screen. In Software mode a running trip must be stopped first:
/// leaving the software app ends its tracking controller.
Future<void> switchAppMode(BuildContext context) async {
  final tracking = Provider.of<TrackingController?>(context, listen: false);
  if (tracking != null && (tracking.isActive || tracking.isBusy)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Stop tracking before switching mode.')),
    );
    return;
  }
  await context.read<AppModeController>().switchMode();
}

/// "Switch mode" as a text button; [onDark] for gradient backgrounds.
class SwitchModeButton extends StatelessWidget {
  const SwitchModeButton({super.key, this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: const ValueKey('switch-mode'),
        style: onDark ? TextButton.styleFrom(foregroundColor: Colors.white) : null,
        onPressed: () => switchAppMode(context),
        icon: const Icon(Icons.swap_horiz),
        label: const Text('Switch mode'),
      );
}

/// "Switch mode" as a settings row.
class SwitchModeTile extends StatelessWidget {
  const SwitchModeTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
        key: const ValueKey('switch-mode'),
        leading: const Icon(Icons.swap_horiz),
        title: const Text('Switch mode'),
        subtitle: const Text('Hardware Prototype or Software System'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => switchAppMode(context),
      );
}
