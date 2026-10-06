/// Monotonic milliseconds. Countdowns use this, never the wall clock, so a clock change on
/// the phone cannot make the displayed time jump.
abstract class MonoClock {
  int nowMs();
}

class SystemMonoClock implements MonoClock {
  final _watch = Stopwatch()..start();

  @override
  int nowMs() => _watch.elapsedMilliseconds;
}

/// Manually advanced clock for tests.
class FakeMonoClock implements MonoClock {
  FakeMonoClock([this.ms = 0]);
  int ms;

  @override
  int nowMs() => ms;

  void advance(int deltaMs) => ms += deltaMs;
}
