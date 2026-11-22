/// Pure-Dart port of the V2I firmware v3 (docs/firmware-v3).
///
/// No Flutter imports: runs in the app, headless, and in unit tests with a [FakeClock].
library;

export 'src/classify.dart';
export 'src/clock.dart';
export 'src/cnum.dart' show cfix, f32, jsonFloat;
export 'src/config.dart';
export 'src/controller.dart';
export 'src/export.dart';
export 'src/geometry.dart';
export 'src/log.dart';
export 'src/metrics.dart';
export 'src/packets.dart';
export 'src/recorder.dart';
export 'src/scenario.dart';
export 'src/vehicle.dart';
