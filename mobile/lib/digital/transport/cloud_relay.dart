import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'links.dart';

typedef ChannelFactory = WebSocketChannel Function(Uri uri);

/// One authenticated connection to the server's relay (/api/v1/v2i/ws). The server decides
/// whether this phone is the intersection or a vehicle from the account; the phone never says.
///
/// - The access token goes in the first message, never in the URL.
/// - Reconnects every 2 s after a drop; on "token expired" it refreshes the token first.
/// - Every 10 minutes it refreshes the token and sends it to extend the connection.
/// - Close codes 4403 / 4404 / 4410 (not allowed, no session, session closed) end it for good.
class RelaySocket {
  RelaySocket({
    required this.uri,
    required this.sessionId,
    required this.accessToken,
    required this.refreshToken,
    ChannelFactory? connect,
    this.retryDelay = const Duration(seconds: 2),
    this.reauthEvery = const Duration(minutes: 10),
  }) : _connect = connect ?? WebSocketChannel.connect;

  final Uri uri;
  final String sessionId;

  /// Current access token (the API client's).
  final String? Function() accessToken;

  /// Refreshes the access token; false when the session cannot be refreshed.
  final Future<bool> Function() refreshToken;
  final ChannelFactory _connect;
  final Duration retryDelay;
  final Duration reauthEvery;

  void Function(Map<String, dynamic> message)? onMessage;
  void Function(LinkState state, String? reason)? onState;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retry, _reauth;
  bool _stopped = false;
  LinkState state = LinkState.closed;

  void start() {
    _stopped = false;
    _open();
    _reauth = Timer.periodic(reauthEvery, (_) => _extend());
  }

  void stop() {
    _stopped = true;
    _retry?.cancel();
    _reauth?.cancel();
    _sub?.cancel();
    _channel?.sink.close(1000);
    _channel = null;
    _set(LinkState.closed, 'stopped');
  }

  void _set(LinkState s, [String? reason]) {
    state = s;
    onState?.call(s, reason);
  }

  void send(Map<String, dynamic> message) {
    if (state != LinkState.online) return; // dropped like a UDP packet while the link is down
    _channel?.sink.add(jsonEncode(message));
  }

  void _open() {
    if (_stopped) return;
    _set(LinkState.connecting);
    final WebSocketChannel ch;
    try {
      ch = _connect(uri);
    } catch (e) {
      _scheduleRetry('$e');
      return;
    }
    _channel = ch;
    _sub = ch.stream.listen(
      (data) {
        if (data is! String) return;
        Object? m;
        try {
          m = jsonDecode(data);
        } on FormatException {
          return;
        }
        if (m is! Map<String, dynamic>) return;
        if (m['k'] == 'hello') _set(LinkState.online);
        onMessage?.call(m);
      },
      onDone: () => _closed(ch.closeCode, ch.closeReason),
      onError: (Object e) => _closed(null, '$e'),
      cancelOnError: true,
    );
    final token = accessToken();
    ch.sink.add(jsonEncode({'type': 'auth', 'accessToken': token ?? '', 'sessionId': sessionId}));
  }

  Future<void> _closed(int? code, String? reason) async {
    _sub?.cancel();
    _channel = null;
    if (_stopped) return;
    switch (code) {
      case 4403 || 4404 || 4410:
        _stopped = true;
        _reauth?.cancel();
        _set(LinkState.closed, switch (code) {
          4410 => 'The session was closed.',
          4404 => 'This session is not open.',
          _ => 'This account is not part of the session.',
        });
        return;
      case 4401:
        try {
          if (!await refreshToken()) {
            _stopped = true;
            _set(LinkState.closed, 'Please sign in again.');
            return;
          }
        } catch (_) {
          // network: retry below
        }
      case 4409:
        _set(LinkState.offline, 'Opened on another connection.');
    }
    _scheduleRetry(reason);
  }

  void _scheduleRetry(String? reason) {
    if (_stopped) return;
    if (state != LinkState.offline) _set(LinkState.offline, reason);
    _retry?.cancel();
    _retry = Timer(retryDelay, _open);
  }

  Future<void> _extend() async {
    if (state != LinkState.online) return;
    try {
      if (await refreshToken()) _channel?.sink.add(jsonEncode({'k': 'auth', 'accessToken': accessToken()}));
    } catch (_) {
      // keep the connection; the next attempt or a reconnect will refresh
    }
  }
}

/// The intersection phone's side of the cloud relay.
class CloudIntersectionLink extends IntersectionLink {
  CloudIntersectionLink(this.socket) {
    socket.onState = (s, r) => onState?.call(s, r);
    socket.onMessage = (m) {
      switch (m['k']) {
        case 'pos':
          final vid = m['vid'], raw = m['raw'];
          if (vid is int && raw is String) onPacket?.call(vid, raw);
        case 'rtt':
          final vid = m['vid'], ms = m['ms'];
          if (vid is int && ms is int) onRtt?.call(vid, ms);
        case 'member':
          final vid = m['vid'];
          if (vid is int) onMember?.call(vid, m['online'] == true, m['emergency'] == true);
        case 'members':
          for (final v in (m['vehicles'] as List? ?? const [])) {
            if (v is Map && v['vid'] is int) onMember?.call(v['vid'] as int, true, v['emergency'] == true);
          }
      }
    };
  }

  final RelaySocket socket;

  @override
  String get label => 'Cloud relay (${socket.uri.host})';

  @override
  void start() => socket.start();

  @override
  void stop() => socket.stop();

  @override
  void sendAck(int vid, String raw) => socket.send({'k': 'ack', 'to': vid, 'raw': raw});

  @override
  void sendState(String raw) => socket.send({'k': 'state', 'raw': raw});
}

/// A vehicle phone's side of the cloud relay.
class CloudVehicleLink extends VehicleLink {
  CloudVehicleLink(this.socket) {
    socket.onState = (s, r) => onState?.call(s, r);
    socket.onMessage = (m) {
      switch (m['k']) {
        case 'hello':
          onIntersection?.call(m['intersectionOnline'] == true);
        case 'ack':
          final raw = m['raw'];
          if (raw is String) onAck?.call(raw);
        case 'intersection':
          onIntersection?.call(m['online'] == true);
        case 'profile':
          onProfile?.call(m['emergency'] == true);
        case 'err':
          onError?.call('${m['code']}', '${m['message'] ?? ''}');
      }
    };
  }

  final RelaySocket socket;

  @override
  String get label => 'Cloud relay (${socket.uri.host})';

  @override
  void start() => socket.start();

  @override
  void stop() => socket.stop();

  @override
  void send(String raw) => socket.send({'k': 'pos', 'raw': raw});

  @override
  void sendRtt(int ms) => socket.send({'k': 'rtt', 'ms': ms});
}
