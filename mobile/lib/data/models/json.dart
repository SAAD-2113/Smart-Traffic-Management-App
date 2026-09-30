/// Small helpers for reading the backend's camelCase JSON safely.
typedef Json = Map<String, dynamic>;

DateTime? parseTime(Object? value) => value == null ? null : DateTime.parse(value as String).toUtc();

double? toDouble(Object? value) => value == null ? null : (value as num).toDouble();

int toInt(Object? value, [int fallback = 0]) => value == null ? fallback : (value as num).toInt();

List<Json> jsonList(Object? value) => ((value as List?) ?? const []).cast<Json>();
