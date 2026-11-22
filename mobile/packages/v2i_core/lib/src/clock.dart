/// Monotonic milliseconds, like the firmware's `millis()`. Signal timing never uses the wall
/// clock: the app passes a Stopwatch-based clock, tests a [FakeClock].
abstract class MonoClock {
  int nowMs();
}

class StopwatchClock implements MonoClock {
  StopwatchClock({int startMs = 0}) : _offset = startMs;
  final int _offset;
  final _watch = Stopwatch()..start();

  @override
  int nowMs() => _offset + _watch.elapsedMilliseconds;
}

class FakeClock implements MonoClock {
  FakeClock([this.ms = 0]);
  int ms;

  @override
  int nowMs() => ms;

  void advance(int deltaMs) => ms += deltaMs;
}
