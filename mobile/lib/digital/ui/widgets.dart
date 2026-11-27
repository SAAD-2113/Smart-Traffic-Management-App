import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/theme/app_theme.dart';
import '../../hardware/ui/hw_style.dart' show HwCard, HwChip;
import '../../widgets/brand.dart';
import '../../widgets/common.dart' show Ticker;
import '../transport/links.dart';

String linkLabel(LinkState s) => switch (s) {
      LinkState.online => 'ONLINE',
      LinkState.connecting => 'CONNECTING',
      LinkState.offline => 'RECONNECTING',
      LinkState.closed => 'CLOSED',
    };

Color linkColor(LinkState s) => switch (s) {
      LinkState.online => StatusColors.ok,
      LinkState.connecting || LinkState.offline => StatusColors.warning,
      LinkState.closed => StatusColors.danger,
    };

/// Header pill with the transport state.
class LinkPill extends StatelessWidget {
  const LinkPill({super.key, required this.state, required this.label});
  final LinkState state;
  final String label;

  @override
  Widget build(BuildContext context) =>
      HeaderPill(key: const ValueKey('link-pill'), label: '$label · ${linkLabel(state)}', dotColor: linkColor(state));
}

/// The join code, large, with its QR code (display only; vehicles type the code).
Future<void> showJoinCode(BuildContext context, String name, String code) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text('Join "$name"'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 220,
            height: 220,
            child: QrImageView(
              key: const ValueKey('join-qr'),
              data: code,
              backgroundColor: Colors.white,
              padding: const EdgeInsets.all(10),
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(code,
              key: const ValueKey('join-code-big'),
              style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: 6)),
          const SizedBox(height: 6),
          Text('On a driver\'s phone: Digital V2I → Join → enter this code.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      );
    },
  );
}

/// The Serial-Monitor-style log of a v2i_core controller or vehicle unit, newest first, with
/// tag filters. Text is exactly what the firmware would print.
class LogCard extends StatefulWidget {
  const LogCard({
    super.key,
    required this.log,
    required this.tags,
    this.title = 'Log',
    this.rxOn,
    this.onToggleRx,
    this.maxShown = 300,
    this.suffix,
  });

  /// Extra text shown after a line (not part of the firmware's line), e.g. an ACK's RTT.
  final String? Function(v2i.LogLine line)? suffix;

  final v2i.V2ILog log;

  /// Tags offered as filters, e.g. ["SIG", "MODE", "PLAN", "PRIO"].
  final List<String> tags;
  final String title;

  /// Intersection only: the [RX] per-packet log switch (the firmware's 'r' command).
  final bool? rxOn;
  final VoidCallback? onToggleRx;
  final int maxShown;

  @override
  State<LogCard> createState() => _LogCardState();
}

class _LogCardState extends State<LogCard> {
  late final Set<String> _on = {...widget.tags};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HwCard(
      title: widget.title,
      icon: Icons.terminal,
      trailing: widget.onToggleRx == null
          ? null
          : FilterChip(
              key: const ValueKey('rx-toggle'),
              label: const Text('[RX] log'),
              selected: widget.rxOn ?? false,
              onSelected: (_) => widget.onToggleRx!(),
            ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in widget.tags)
            FilterChip(
              key: ValueKey('tag-$t'),
              label: Text(t),
              selected: _on.contains(t),
              visualDensity: VisualDensity.compact,
              onSelected: (v) => setState(() => v ? _on.add(t) : _on.remove(t)),
            ),
        ]),
        const SizedBox(height: 8),
        Ticker(
          period: const Duration(milliseconds: 500),
          builder: (context) {
            final lines = <v2i.LogLine>[];
            final all = widget.log.lines;
            for (var i = all.length - 1; i >= 0 && lines.length < widget.maxShown; i--) {
              final t = all[i].tag;
              if (_on.contains(t) || (t == '' && _on.length == widget.tags.length)) lines.add(all[i]);
            }
            if (lines.isEmpty) return Text('Nothing logged yet.', style: theme.textTheme.bodyMedium);
            return Container(
              height: 320,
              decoration: BoxDecoration(color: const Color(0xFF0E0E0E), borderRadius: BorderRadius.circular(10)),
              child: ListView.builder(
                key: const ValueKey('log-list'),
                padding: const EdgeInsets.all(8),
                itemCount: lines.length,
                itemBuilder: (_, i) {
                  final l = lines[i];
                  final extra = widget.suffix?.call(l);
                  return Text(
                    '${_time(l)}  ${l.text}${extra == null ? '' : '   $extra'}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.35,
                      color: switch (l.tag) {
                        'PRIO' => const Color(0xFFFF8A80),
                        'SIG' => const Color(0xFFB9F6CA),
                        'MODE' || 'PLAN' => const Color(0xFFFFE082),
                        'RX!' || 'LOST' || 'MISMATCH' || 'TX!' => const Color(0xFFFFD180),
                        _ => const Color(0xFFE7E5E4),
                      },
                    ),
                  );
                },
              ),
            );
          },
        ),
      ]),
    );
  }

  /// Phone wall-clock time of the line (labels only; timing never uses it).
  static String _time(v2i.LogLine l) {
    final w = l.wall?.toLocal();
    if (w == null) return '${(l.ms / 1000).toStringAsFixed(3)}s';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(w.hour)}:${two(w.minute)}:${two(w.second)}.${(w.millisecond ~/ 100)}';
  }
}

/// A labelled figure for cards.
class Figure extends StatelessWidget {
  const Figure(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 2),
      Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

/// Median of measured samples, or null.
int? median(List<int> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

const emergencyChip = HwChip(label: 'EMERGENCY', color: StatusColors.emergency, icon: Icons.emergency);
