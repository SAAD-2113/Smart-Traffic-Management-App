import 'dart:async';

import 'package:flutter/material.dart';

import '../core/network/api_exception.dart';
import '../core/theme/app_theme.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.color, this.icon, this.filled = false});

  final String label;
  final Color color;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: filled ? Colors.white : color), const SizedBox(width: 4)],
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: filled ? Colors.white : color, letterSpacing: 0.2)),
      ]),
    );
  }
}

class CongestionBadge extends StatelessWidget {
  const CongestionBadge(this.level, {super.key, this.compact = false});
  final String level;
  final bool compact;

  static String label(String level) => switch (level) {
        'LOW' => 'Low',
        'MODERATE' => 'Moderate',
        'HIGH' => 'High',
        'SEVERE' => 'Severe',
        _ => 'No data',
      };

  @override
  Widget build(BuildContext context) => StatusChip(
        label: compact ? label(level) : 'Congestion: ${label(level)}',
        color: StatusColors.congestion(level),
        filled: level == 'HIGH' || level == 'SEVERE',
      );
}

class DataQualityChip extends StatelessWidget {
  const DataQualityChip(this.quality, {super.key});
  final String quality;

  @override
  Widget build(BuildContext context) {
    final color = switch (quality) {
      'HIGH' => StatusColors.ok,
      'MEDIUM' => StatusColors.info,
      'LOW' => StatusColors.warning,
      _ => StatusColors.neutral,
    };
    return Tooltip(
      message: 'Data quality: how many vehicles the numbers are based on',
      child: StatusChip(label: 'Data ${quality.toLowerCase()}', color: color, icon: Icons.insights),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.icon,
    this.color,
    this.caption,
    this.onTap,
  });

  final String label;
  final String value;
  final String? unit;
  final IconData? icon;
  final Color? color;
  final String? caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              if (icon != null) Icon(icon, size: 18, color: accent),
              if (icon != null) const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ]),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Flexible(
                child: Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: accent)),
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(unit!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ]),
            if (caption != null) ...[
              const SizedBox(height: 4),
              Text(caption!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (subtitle != null)
              Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.cloud_off,
        title: 'Something went wrong',
        message: message,
        action: onRetry == null ? null : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
      );
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          if (label != null) ...[const SizedBox(height: 12), Text(label!)],
        ]),
      );
}

/// Label/value rows for detail screens.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 150,
          child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: valueColor)),
        ),
      ]),
    );
  }
}

/// Press and hold to confirm: used for actions that must not happen by accident.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.color = StatusColors.emergency,
    this.holdDuration = const Duration(seconds: 2),
    this.enabled = true,
  });

  final String label;
  final VoidCallback onConfirmed;
  final Color color;
  final Duration holdDuration;
  final bool enabled;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.holdDuration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _controller.reset();
        widget.onConfirmed();
      }
    });

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.enabled ? widget.color : Theme.of(context).disabledColor;
    return Semantics(
      button: true,
      label: '${widget.label}. Press and hold for ${widget.holdDuration.inSeconds} seconds.',
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => _controller.forward() : null,
        onTapUp: (_) => _controller.reverse(),
        onTapCancel: () => _controller.reverse(),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Container(
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color, width: 2),
              gradient: LinearGradient(
                colors: [color, color, color.withValues(alpha: 0.08), color.withValues(alpha: 0.08)],
                stops: [0, _controller.value, _controller.value, 1],
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              _controller.value > 0 ? 'Keep holding…' : widget.label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: _controller.value > 0.5 ? Colors.white : color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void showError(BuildContext context, Object error) {
  final message = error is ApiException ? error.userMessage : error.toString();
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}

/// Runs an async action with error reporting; returns true on success.
Future<bool> runGuarded(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) showInfo(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Asks for a short reason (audited actions such as suspending a vehicle).
Future<String?> askReason(BuildContext context, {required String title, required String hint, String action = 'Confirm'}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 300,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().length >= 3) Navigator.pop(context, controller.text.trim());
          },
          child: Text(action),
        ),
      ],
    ),
  );
}

/// Rebuilds every [period] (for "x seconds ago" labels).
class Ticker extends StatefulWidget {
  const Ticker({super.key, required this.builder, this.period = const Duration(seconds: 1)});
  final WidgetBuilder builder;
  final Duration period;

  @override
  State<Ticker> createState() => _TickerState();
}

class _TickerState extends State<Ticker> {
  late final Timer _timer = Timer.periodic(widget.period, (_) => setState(() {}));

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class MessageBanner extends StatelessWidget {
  const MessageBanner({super.key, required this.text, required this.color, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null) ...[Icon(icon, color: color, size: 20), const SizedBox(width: 10)],
          Expanded(child: Text(text)),
        ]),
      );
}
