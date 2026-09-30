import 'package:intl/intl.dart';

/// The backend speaks SI units (m/s, metres, UTC). The UI shows km/h and local time.
class Units {
  static const mpsToKmh = 3.6;

  static double kmh(double mps) => mps * mpsToKmh;

  static String speed(double? mps, {int decimals = 0}) =>
      mps == null ? '—' : '${kmh(mps).toStringAsFixed(decimals)} km/h';

  static String speedValue(double? mps) => mps == null ? '—' : kmh(mps).toStringAsFixed(0);

  static String distance(double? metres) {
    if (metres == null) return '—';
    if (metres < 1000) return '${metres.toStringAsFixed(0)} m';
    return '${(metres / 1000).toStringAsFixed(metres < 10000 ? 2 : 1)} km';
  }

  static String duration(double? seconds) {
    if (seconds == null) return '—';
    final s = seconds.round();
    if (s < 60) return '$s s';
    final m = s ~/ 60;
    if (m < 60) return '$m min ${s % 60} s';
    return '${m ~/ 60} h ${m % 60} min';
  }

  static String heading(double? deg) {
    if (deg == null) return '—';
    const names = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return '${deg.toStringAsFixed(0)}° ${names[((deg % 360) / 45).round() % 8]}';
  }

  static String coordinate(double? value) => value == null ? '—' : value.toStringAsFixed(6);

  static String ago(DateTime? time, {DateTime? now}) {
    if (time == null) return 'never';
    final diff = (now ?? DateTime.now()).difference(time);
    if (diff.inSeconds < 2) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds} s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return DateFormat.yMMMd().format(time.toLocal());
  }

  static String clock(DateTime? time) => time == null ? '—' : DateFormat.Hms().format(time.toLocal());

  static String dateTime(DateTime? time) => time == null ? '—' : DateFormat('d MMM yyyy, HH:mm').format(time.toLocal());

  static String number(num? value, {int decimals = 0}) => value == null ? '—' : value.toStringAsFixed(decimals);

  static String percent(double? ratio) => ratio == null ? '—' : '${(ratio * 100).toStringAsFixed(0)} %';
}
