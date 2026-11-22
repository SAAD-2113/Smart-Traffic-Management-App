import 'dart:typed_data';

/// Float32 emulation and C `printf` number formatting.
///
/// The ESP32 firmware computes most values in `float` (32-bit) and prints them with `printf`.
/// To give the same numbers, the port rounds to float32 wherever the firmware stores or
/// computes a `float` ([f32]), and formats numbers the way glibc's `printf` does ([cfix]):
/// exact decimal value, ties rounded to even.

final _f32buf = Float32List(1);

/// Rounds [x] to the nearest float32 value (what a C `float` holds).
double f32(num x) {
  _f32buf[0] = x.toDouble();
  return _f32buf[0];
}

/// C `fmodf` / `fmod`: remainder with the sign of the dividend.
double cfmod(double a, double b) => a.remainder(b);

/// C `roundf`: half away from zero, in float.
double croundf(double x) => f32(x.roundToDouble());

/// `printf("%.<decimals>f", x)`: exact decimal expansion of the double, ties to even.
String cfix(num value, int decimals) {
  final x = value.toDouble();
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return x < 0 ? '-inf' : 'inf';
  final negative = x.isNegative; // includes -0.0, which printf prints as "-0.0"
  final bits = ByteData(8)..setFloat64(0, x.abs());
  final raw = bits.getUint64(0);
  final exponentBits = (raw >> 52) & 0x7FF;
  var mantissa = BigInt.from(raw & 0xFFFFFFFFFFFFF);
  int exponent;
  if (exponentBits == 0) {
    exponent = -1074; // subnormal
  } else {
    mantissa += BigInt.one << 52;
    exponent = exponentBits - 1075;
  }
  // value = mantissa * 2^exponent; scaled = value * 10^decimals
  var numerator = mantissa * BigInt.from(10).pow(decimals);
  BigInt q;
  if (exponent >= 0) {
    q = numerator << exponent;
  } else {
    final den = BigInt.one << -exponent;
    q = numerator ~/ den;
    final twiceRem = (numerator % den) * BigInt.two;
    if (twiceRem > den || (twiceRem == den && q.isOdd)) q += BigInt.one;
  }
  var digits = q.toString();
  if (decimals > 0) {
    if (digits.length <= decimals) digits = digits.padLeft(decimals + 1, '0');
    digits = '${digits.substring(0, digits.length - decimals)}.${digits.substring(digits.length - decimals)}';
  }
  return negative ? '-$digits' : digits;
}

/// `printf("%<width>.<decimals>f")`, right-aligned.
String cfixw(num value, int width, int decimals) => cfix(value, decimals).padLeft(width);

/// The shortest decimal that reads back as the same float32. ArduinoJson prints `float`
/// values this way ("44.6", not 44.59999847); whole numbers become integers ("30").
num jsonFloat(double float32Value) {
  if (!float32Value.isFinite) return 0;
  if (float32Value == float32Value.roundToDouble() && float32Value.abs() < 1e15) return float32Value.round();
  for (var p = 1; p <= 9; p++) {
    final candidate = double.parse(float32Value.toStringAsPrecision(p));
    if (f32(candidate) == float32Value) return candidate;
  }
  return float32Value;
}

/// The same for a C `double` (whole numbers become integers).
num jsonDouble(double value) {
  if (!value.isFinite) return 0;
  if (value == value.roundToDouble() && value.abs() < 1e15) return value.round();
  return value;
}
