import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../widgets/brand.dart';
import '../widgets/glass.dart';
import 'app_mode.dart';

/// First screen on launch (before any login): Hardware Prototype, Software System or Digital V2I.
class ModeSelectionScreen extends StatefulWidget {
  const ModeSelectionScreen({super.key});

  @override
  State<ModeSelectionScreen> createState() => _ModeSelectionScreenState();
}

class _ModeSelectionScreenState extends State<ModeSelectionScreen> {
  late bool _remember = context.read<AppModeController>().remember;

  void _choose(AppMode mode) => context.read<AppModeController>().choose(mode, remember: _remember);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final cards = [
      _ModeCard(
        key: const ValueKey('mode-hardware'),
        icon: Icons.developer_board,
        title: 'Hardware Prototype',
        subtitle: 'Live monitor for the physical V2I intersection',
        note: 'Works offline · no login · read-only',
        gradient: const LinearGradient(colors: [Color(0xFFB45309), Color(0xFFF59E0B)]),
        onTap: () => _choose(AppMode.hardware),
      ),
      _ModeCard(
        key: const ValueKey('mode-software'),
        icon: Icons.hub_outlined,
        title: 'Software System',
        subtitle: 'Full app, trips and analysis',
        note: 'Sign in · needs the server',
        gradient: Brand.action,
        onTap: () => _choose(AppMode.software),
      ),
      _ModeCard(
        key: const ValueKey('mode-digital'),
        icon: Icons.phonelink_ring_outlined,
        title: 'Digital V2I',
        subtitle: 'Phones as the intersection and the vehicles (firmware v3 twin)',
        note: 'Sign in · needs the server',
        gradient: const LinearGradient(colors: [Color(0xFFB91C1C), Color(0xFFF97316)]),
        onTap: () => _choose(AppMode.digital),
      ),
    ];
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 1040 : 460),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Center(child: TrafficLightLogo(size: 92)),
                const SizedBox(height: 16),
                Text('Smart Traffic',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: theme.colorScheme.onSurface, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                const SizedBox(height: 4),
                Text('Choose how to use the app', textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 15)),
                const SizedBox(height: 24),
                if (wide)
                  IntrinsicHeight(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < cards.length; i++) ...[
                        if (i > 0) const SizedBox(width: 16),
                        Expanded(child: cards[i]),
                      ],
                    ]),
                  )
                else
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    cards[i],
                  ],
                const SizedBox(height: 18),
                Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _remember = !_remember),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Checkbox(
                          value: _remember,
                          onChanged: (v) => setState(() => _remember = v ?? false),
                        ),
                        const Text('Remember my choice', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ),
                Text('You can change it later with "Switch mode".',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 12.5)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.note,
    required this.gradient,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String note;
  final Gradient gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(gradient: gradient, borderRadius: BorderRadius.circular(17)),
              child: Icon(icon, color: Colors.white, size: 31),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(subtitle, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
                Text(note, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
            Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}
