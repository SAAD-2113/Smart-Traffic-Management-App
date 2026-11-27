import 'dart:convert';

import 'cnum.dart';
import 'config.dart';

/// Reads a JSON object the way the firmware reads it with ArduinoJson:
/// `d["x"] | default` returns the default when the value is missing or of another type,
/// `d["x"].isNull()` is true when it is missing or null.
class ArduinoJsonDoc {
  ArduinoJsonDoc(this.map, [this._fractional = const {}]);
  final Map<String, Object?> map;

  /// Keys whose number was written with a fraction or an exponent ("7.0", "7e0"). ArduinoJson
  /// stores those as float, so integer reads reject them. The Dart VM decodes them as double
  /// anyway, but compiled to JavaScript (web build) 7.0 and 7 are the same number, so the
  /// source text is the only way to tell.
  final Set<String> _fractional;

  static final _numberField = RegExp(r'"((?:[^"\\]|\\.)*)"\s*:\s*-?\d+(\.\d*)?([eE][+-]?\d+)?');

  /// Parses [text]; null when it is not a JSON object.
  static ArduinoJsonDoc? parse(String text) {
    try {
      final v = jsonDecode(text);
      if (v is Map) {
        final fractional = <String>{
          for (final m in _numberField.allMatches(text))
            if (m.group(2) != null || m.group(3) != null) ?_key(m.group(1)!),
        };
        return ArduinoJsonDoc(v.map((k, val) => MapEntry('$k', val)), fractional);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// The key text of a match, unescaped; null when it is not a valid JSON string (the match was
  /// inside a string value), so such text never makes a packet bad.
  static String? _key(String raw) {
    try {
      final k = jsonDecode('"$raw"');
      return k is String ? k : null;
    } on FormatException {
      return null;
    }
  }

  /// An integer as ArduinoJson sees it: written without a fraction or exponent.
  bool _isInt(String key, Object? v) => v is int && !_fractional.contains(key);

  bool isNull(String key) => map[key] == null;

  /// `d[key] | ""` / `d[key] | "?"`
  String str(String key, String def) {
    final v = map[key];
    return v is String ? v : def;
  }

  /// `d[key] | 0` (int): integer values only.
  int intOr(String key, int def) {
    final v = map[key];
    return _isInt(key, v) ? v as int : def;
  }

  /// `d[key] | 0UL`: non-negative integers within uint32.
  int uintOr(String key, int def) {
    final v = map[key];
    return _isInt(key, v) && (v as int) >= 0 && v <= 0xFFFFFFFF ? v : def;
  }

  /// `d[key] | 0.0f`: any number, as float.
  double floatOr(String key, double def) {
    final v = map[key];
    return v is num ? f32(v) : def;
  }

  /// `d[key].as<float>()` / `as<double>()`: a number, else 0.
  double asFloat(String key) {
    final v = map[key];
    return v is num ? f32(v) : 0.0;
  }

  double asDouble(String key) {
    final v = map[key];
    return v is num ? v.toDouble() : 0.0;
  }

  /// `d[key].as<uint32_t>()`: integers in range, floats truncated, else 0.
  int asUint32(String key) {
    final v = map[key];
    if (_isInt(key, v)) return (v as int) >= 0 && v <= 0xFFFFFFFF ? v : 0;
    if (v is num) {
      final d = v.toDouble();
      if (d.isFinite && d >= 0 && d < 4294967296.0) return d.truncate();
    }
    return 0;
  }
}

/// `strlcpy(dst, src, size)`: at most size-1 bytes.
String strlcpy(String src, int size) {
  final bytes = utf8.encode(src);
  if (bytes.length <= size - 1) return src;
  return utf8.decode(bytes.sublist(0, size - 1), allowMalformed: true);
}

/// Vehicle -> intersection packet (every 500 ms).
/// `{"t":"pos","id":101,"ty":0,"lat":31.500808,"lon":74.300000,"spd":29.8,"hdg":180,"seq":42,
///   "hw":"ESP32-S3","tl":"N","rssi":-52}`
/// `hdg`, `tl` and `rssi` are optional (a phone may not have them); the firmware treats a
/// missing `hdg` as "no heading" and uses its "getting closer" fallback.
class PosPacket {
  const PosPacket({
    required this.id,
    required this.ty,
    required this.lat,
    required this.lon,
    required this.spd,
    this.hdg,
    required this.seq,
    required this.hw,
    this.tl,
    this.rssi,
  });

  final int id;
  final int ty;
  final double lat;
  final double lon;

  /// km/h, already rounded to 0.1 as transmitted.
  final double spd;

  /// Degrees, 0..359, or null (not sent).
  final int? hdg;
  final int seq;
  final String hw;
  final String? tl;
  final int? rssi;

  /// Same text as the firmware's `snprintf` (optional fields left out when null).
  String encode() {
    final b = StringBuffer('{"t":"pos","id":$id,"ty":$ty,"lat":${cfix(lat, 6)},"lon":${cfix(lon, 6)},"spd":${cfix(spd, 1)}');
    if (hdg != null) b.write(',"hdg":$hdg');
    b.write(',"seq":$seq,"hw":"${_esc(hw)}"');
    if (tl != null) b.write(',"tl":"${_esc(tl!)}"');
    if (rssi != null) b.write(',"rssi":$rssi');
    b.write('}');
    return b.toString();
  }
}

String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// Intersection -> vehicle reply to every "pos".
/// `{"t":"ack","id":101,"seq":42,"mode":"adaptive","lane":"N","st":"QUEUED","sig":"R","rem":11.4,"pri":0}`
class AckPacket {
  const AckPacket({
    required this.id,
    required this.seq,
    required this.mode,
    required this.lane,
    required this.st,
    required this.sig,
    required this.rem,
    required this.pri,
  });

  final int id;
  final int seq;
  final String mode;

  /// "N" / "E" / "S" / "W", or "-" when the vehicle has no lane.
  final String lane;
  final String st;

  /// "G" / "Y" / "R" for the vehicle's lane, "-" without a lane.
  final String sig;

  /// Seconds left in that colour (R -> estimated time to green).
  final double rem;
  final int pri;

  bool get hasLane => lane != '-';

  /// The firmware's two `snprintf` layouts ("rem":%.1f with a lane, "rem":0 without).
  String encode() => hasLane
      ? '{"t":"ack","id":$id,"seq":$seq,"mode":"$mode","lane":"$lane","st":"$st","sig":"$sig","rem":${cfix(rem, 1)},"pri":$pri}'
      : '{"t":"ack","id":$id,"seq":$seq,"mode":"$mode","lane":"-","st":"$st","sig":"-","rem":0,"pri":$pri}';

  /// Reads an ACK the way vehicle_node.ino does; null if it is not an ACK.
  static AckPacket? decode(String text) {
    final d = ArduinoJsonDoc.parse(text);
    if (d == null || d.str('t', '') != 'ack') return null;
    return AckPacket(
      id: d.intOr('id', 0),
      seq: d.uintOr('seq', 0),
      mode: strlcpy(d.str('mode', '-'), 12),
      lane: strlcpy(d.str('lane', '-'), 4),
      st: strlcpy(d.str('st', '-'), 16),
      sig: d.str('sig', 'R'),
      rem: d.floatOr('rem', 0.0),
      pri: d.intOr('pri', 0),
    );
  }
}

/// Byte length of a packet as sent (UTF-8).
int packetBytes(String packet) => utf8.encode(packet).length;

/// True when a packet fits the firmware's buffer (V2I_MAX_PACKET, including the terminator).
bool fitsPacket(String packet) => packetBytes(packet) < V2I_MAX_PACKET;
