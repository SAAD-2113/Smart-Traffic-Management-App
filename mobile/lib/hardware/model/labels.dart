// Words and number formats for the hardware monitor. Missing values are shown as "—".

const dash = '—';

String approachName(String? a) => switch (a) {
      'N' => 'North',
      'S' => 'South',
      'E' => 'East',
      'W' => 'West',
      null => dash,
      _ => a,
    };

String phaseName(String? p) => switch (p) {
      'NS' => 'NORTH/SOUTH',
      'EW' => 'EAST/WEST',
      'NONE' => 'NO PHASE',
      null => dash,
      _ => p,
    };

String intervalName(String? i) => switch (i) {
      'green' => 'GREEN',
      'yellow' => 'YELLOW',
      'all_red' => 'ALL RED',
      'startup' => 'STARTUP',
      'flash' => 'FLASHING',
      null => dash,
      _ => i.toUpperCase(),
    };

/// "NORTH/SOUTH — GREEN"; all-red, startup and flash concern the whole intersection.
String phaseLine(String? phase, String? interval) {
  if (phase == null && interval == null) return dash;
  if (interval == 'startup' || interval == 'flash' || phase == 'NONE') return intervalName(interval);
  return '${phaseName(phase)} — ${intervalName(interval)}';
}

String modeName(String? m) => switch (m) {
      'adaptive' => 'ADAPTIVE',
      'fixed' => 'FIXED',
      null => dash,
      _ => m.toUpperCase(),
    };

String ctrlName(String? c) => switch (c) {
      'startup' => 'Starting up',
      'normal' => 'Normal',
      'rest' => 'Rest',
      'idle' => 'Idle',
      'preempt' => 'Emergency preemption',
      'fallback' => 'Fixed-time fallback',
      'fault' => 'FAULT',
      null => dash,
      _ => c,
    };

String levelName(String? l) => switch (l) {
      'free' => 'Free',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      null => dash,
      _ => l,
    };

String eventName(String? e) => switch (e) {
      'phase_change' => 'Phase change',
      'mode_change' => 'Mode change',
      'ev_request' => 'Emergency request',
      'preempt_start' => 'Preemption started',
      'preempt_end' => 'Preemption ended',
      'v2i_lost' => 'V2I link lost',
      'v2i_restored' => 'V2I link restored',
      'restart' => 'Controller start',
      null => 'Event',
      _ => e,
    };

String vehicleStateName(String? s) => switch (s) {
      'approaching' => 'Approaching',
      'queued' => 'Queued',
      'departed' => 'Departed',
      null => dash,
      _ => s,
    };

String orDash(Object? v) => v == null ? dash : '$v';

String seconds(num? s, {int decimals = 0}) => s == null ? dash : '${s.toStringAsFixed(decimals)} s';

String secondsFromMs(int? ms, {int decimals = 1}) => ms == null ? dash : '${(ms / 1000).toStringAsFixed(decimals)} s';

/// Controller uptime: "12 min 45 s", "3 h 05 min".
String uptime(int? ms) {
  if (ms == null || ms < 0) return dash;
  final s = ms ~/ 1000;
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  if (m < 60) return '$m min ${(s % 60).toString().padLeft(2, '0')} s';
  final h = m ~/ 60;
  if (h < 48) return '$h h ${(m % 60).toString().padLeft(2, '0')} min';
  return '${h ~/ 24} d ${h % 24} h';
}

/// "0.3 s ago", "12 s ago", "4 min ago".
String ago(int? ms) {
  if (ms == null) return dash;
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)} s ago';
  if (ms < 120000) return '${ms ~/ 1000} s ago';
  return '${ms ~/ 60000} min ago';
}

String clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
