import 'frame_v3.dart';

/// What the four-lane (firmware v3) cards need. The Hardware monitor implements it from the
/// ESP32's frames; the Digital V2I intersection screen implements it from its own controller.
abstract class V3View {
  /// The latest state, or null before the first one.
  V3State? get v3;

  /// The state is current (frames are arriving).
  bool get isLive;

  /// A state is shown but it is not current.
  bool get showingLastKnown;

  /// The lane's MM:SS display, counted down locally between states.
  String? laneDisplay(String lane);

  /// Seconds left in the current phase (large countdown).
  int? get countdownS;
  int? get remainingMs;
  int? get elapsedMs;

  /// Share of the current phase done, 0..1.
  double? get progress;

  /// Where the countdown comes from, e.g. "Countdown from the controller".
  String get countdownSource;
}
