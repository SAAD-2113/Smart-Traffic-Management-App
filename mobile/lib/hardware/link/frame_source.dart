/// Where frames come from: the ESP32 WebSocket or the built-in simulator. Both deliver the
/// same JSON text, which goes through the same parser.
abstract class FrameSource {
  /// A text frame arrived.
  void Function(String text)? onFrame;

  /// The connection opened (true) or closed (false).
  void Function(bool open)? onOpen;

  bool get isSimulator;

  /// Short description for the header, e.g. "ws://192.168.4.1:81/".
  String get label;

  void start();
  void stop();
}
