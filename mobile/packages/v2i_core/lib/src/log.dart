/// One log line: the Serial Monitor text, the monotonic time it was printed and (optionally)
/// the wall-clock time, used only to label exports.
class LogLine {
  LogLine(this.ms, this.text, {this.wall});

  final int ms;
  final String text;
  final DateTime? wall;

  /// "SIG", "PLAN", "MODE", "PRIO", "CONN", "LOST", "RX", "RX!", "MISMATCH", "STAT", "TX",
  /// "ACK", "BASIS", "SIM", "APP" ... or "" for untagged lines.
  String get tag => logTag(text);

  @override
  String toString() => text;
}

final _tagRe = RegExp(r'^\[([^\]]+)\]');

String logTag(String text) => _tagRe.firstMatch(text)?.group(1)?.trim() ?? '';

/// Bounded log with a listener, shared by the controller and the vehicle.
class V2ILog {
  V2ILog({this.capacity = 5000});

  final int capacity;
  final lines = <LogLine>[];
  final _listeners = <void Function(LogLine)>[];

  void add(LogLine line) {
    lines.add(line);
    // trim in chunks (keeps between capacity and 1.2 x capacity lines)
    if (lines.length > capacity + capacity ~/ 5) lines.removeRange(0, lines.length - capacity);
    for (final l in List.of(_listeners)) {
      l(line);
    }
  }

  void listen(void Function(LogLine) f) => _listeners.add(f);
  void unlisten(void Function(LogLine) f) => _listeners.remove(f);
}
