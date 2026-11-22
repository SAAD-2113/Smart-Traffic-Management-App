/// How the digital intersection and the vehicles reach each other. The signal logic never
/// depends on the transport: the intersection side gets packet texts and answers with ACK
/// texts, the vehicle side sends packet texts and gets ACK texts, exactly as over UDP/HTTP to the
/// ESP32. Phase 2: CloudRelayTransport (server WebSocket). Later: LAN, hardware bridge.
library;

enum LinkState {
  /// Opening or re-opening the connection.
  connecting,

  /// Connected and authenticated.
  online,

  /// Connection lost; retrying.
  offline,

  /// Ended for good (session closed, access refused, or stopped).
  closed,
}

/// Intersection side.
abstract class IntersectionLink {
  /// A vehicle's "pos" packet text, unchanged ([vid] is the id the transport vouches for).
  void Function(int vid, String raw)? onPacket;

  /// A vehicle reported its packet -> ACK round-trip time.
  void Function(int vid, int ms)? onRtt;

  /// A vehicle's phone connected or disconnected (before it sends anything).
  void Function(int vid, bool online, bool emergency)? onMember;

  void Function(LinkState state, String? reason)? onState;

  /// Short description, e.g. "Cloud relay (wss://…)".
  String get label;

  void start();
  void stop();
  void sendAck(int vid, String raw);
  void sendState(String raw);
}

/// Vehicle side.
abstract class VehicleLink {
  void Function(String raw)? onAck;
  void Function(LinkState state, String? reason)? onState;

  /// The intersection phone is connected (true) or not.
  void Function(bool online)? onIntersection;

  /// An admin changed this account's emergency authorisation.
  void Function(bool emergency)? onProfile;

  /// The server refused a packet (code, message).
  void Function(String code, String message)? onError;

  String get label;

  void start();
  void stop();
  void send(String raw);
  void sendRtt(int ms);
}
