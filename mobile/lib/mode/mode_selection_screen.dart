import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import 'app_mode.dart';

/// First screen on launch (before any login): Hardware Prototype or Software System.
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
        gradient: const LinearGradient(colors: [Color(0xFF0F766E), Color(0xFF14B8A6)]),
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
    ];
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: Brand.hero),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: wide ? 760 : 460),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: Brand.action,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [BoxShadow(color: Brand.cyan.withValues(alpha: 0.45), blurRadius: 24)],
                      ),
                      child: const Icon(Icons.traffic, size: 46, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Smart Traffic',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  const SizedBox(height: 4),
                  Text('Choose how to use the app',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 15)),
                  const SizedBox(height: 24),
                  if (wide)
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(child: cards[0]),
                        const SizedBox(width: 16),
                        Expanded(child: cards[1]),
                      ]),
                    )
                  else ...[
                    cards[0],
                    const SizedBox(height: 14),
                    cards[1],
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
                            side: const BorderSide(color: Colors.white70, width: 1.6),
                            checkColor: Brand.navy,
                            fillColor: WidgetStateProperty.resolveWith(
                                (s) => s.contains(WidgetState.selected) ? Colors.white : Colors.transparent),
                          ),
                          const Text('Remember my choice',
                              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                  ),
                  Text('You can change it later with "Switch mode".',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12.5)),
                ]),
              ),
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
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(gradient: gradient, borderRadius: BorderRadius.circular(18)),
              child: Icon(icon, color: Colors.white, size: 34),
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
