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

  // Set by the intersection for transports that mirror the ESP32's own server (LAN):
  /// The state JSON now (GET /api/state builds it on request, like the firmware).
  String Function()? stateNow;

  /// GET /api/mode?m=…: applies the mode and returns the firmware's reply JSON.
  String Function(String m)? onModeRequest;

  /// A text message from a WebSocket client (mode commands, as on port 81).
  void Function(String text)? onWsText;

  /// A WebSocket client connected (true) or disconnected.
  void Function(int client, bool connected)? onWsClient;

  /// Short description, e.g. "Cloud relay (wss://…)".
  String get label;

  void start();
  void stop();
  void sendAck(int vid, String raw);
  void sendState(String raw);
}

/// Several transports into one intersection (e.g. the cloud relay and the LAN at once). Each ACK
/// goes back over the transport that brought that vehicle's last packet.
class CompositeIntersectionLink extends IntersectionLink {
  CompositeIntersectionLink(this.links) {
    for (final l in links) {
      l
        ..onPacket = ((vid, raw) {
          _route[vid] = l;
          onPacket?.call(vid, raw);
        })
        ..onRtt = ((vid, ms) => onRtt?.call(vid, ms))
        ..onMember = ((vid, on, em) => onMember?.call(vid, on, em))
        ..onState = ((s, r) => onState?.call(_combined(), r))
        ..stateNow = (() => stateNow?.call() ?? '{}')
        ..onModeRequest = ((m) => onModeRequest?.call(m) ?? '{"ok":false}')
        ..onWsText = ((t) => onWsText?.call(t))
        ..onWsClient = ((c, on) => onWsClient?.call(c, on));
    }
  }

  final List<IntersectionLink> links;
  final _route = <int, IntersectionLink>{};
  final _states = <IntersectionLink, LinkState>{};

  /// Online when any transport is online; otherwise the best of the others.
  LinkState _combined() {
    for (final s in const [LinkState.online, LinkState.connecting, LinkState.offline]) {
      if (_states.values.contains(s)) return s;
    }
    return LinkState.closed;
  }

  @override
  String get label => links.map((l) => l.label).join(' + ');

  @override
  void start() {
    for (final l in links) {
      final inner = l.onState;
      l.onState = (s, r) {
        _states[l] = s;
        inner?.call(s, r);
      };
      l.start();
    }
  }

  @override
  void stop() {
    for (final l in links) {
      l.stop();
    }
  }

  /// The state of one of the transports (null before it reported).
  LinkState? stateOf(IntersectionLink l) => _states[l];

  @override
  void sendAck(int vid, String raw) => (_route[vid] ?? links.first).sendAck(vid, raw);

  @override
  void sendState(String raw) {
    for (final l in links) {
      l.sendState(raw);
    }
  }
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

  /// Request/response transports (HTTP, like a vehicle POSTing to the ESP32) send whether or
  /// not the last request worked, as a UDP vehicle keeps beaconing.
  bool get connectionless => false;

  void start();
  void stop();
  void send(String raw);
  void sendRtt(int ms);
}
