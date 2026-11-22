import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'links.dart';

/// LanTransport: the intersection phone serves what the ESP32 serves, on a phone hotspot or a
/// shared Wi-Fi, so phones (and laptops, curl, the Hardware-mode dashboard) can reach it
/// without the server:
///
///   HTTP  :8080  GET /api/state · GET /api/mode?m=auto|fixed|adaptive · POST /api/vehicle
///   WS    :8081  the state JSON every 500 ms; accepts mode commands ("fixed", {"mode":"auto"})
///   UDP   :4210  pos packets; the ACK goes back to the sender's address and port
///
/// Android apps cannot open ports below 1024, so HTTP is 8080 and the WebSocket 8081 instead of
/// the ESP32's 80 / 81 (both can be changed). The phone's address depends on the network (a phone
/// hotspot is usually 192.168.43.1 or 10.x.x.x, not 192.168.4.1): [addresses] lists it.
///
/// Emergency packets ("ty" not 0): on a LAN no server checks the account, so they are refused
/// unless the host allows them ([allowEmergency]), which is how the ESP32 prototype behaves.
class LanIntersectionLink extends IntersectionLink {
  LanIntersectionLink({this.httpPort = 8080, this.wsPort = 8081, this.udpPort = 4210, this.allowEmergency = false});

  final int httpPort;
  final int wsPort;

  /// Negative = no UDP; 0 = any free port (tests).
  final int udpPort;
  bool allowEmergency;

  HttpServer? _http, _ws;
  RawDatagramSocket? _udp;
  final _clients = <int, WebSocket>{};
  int _nextClient = 0;
  String? _lastState;
  final _ready = Completer<void>();

  /// Ports actually opened (after [ready]); useful with port 0 in tests.
  int get boundHttpPort => _http?.port ?? httpPort;
  int get boundWsPort => _ws?.port ?? wsPort;
  int get boundUdpPort => _udp?.port ?? udpPort;

  Future<void> get ready => _ready.future;

  /// Packets refused because of [allowEmergency].
  int refusedEmergency = 0;

  @override
  String get label => 'LAN :$boundHttpPort / ws :$boundWsPort${_udp != null ? ' / udp $boundUdpPort' : ''}';

  @override
  void start() {
    onState?.call(LinkState.connecting, null);
    _open().then((_) {
      onState?.call(LinkState.online, null);
      if (!_ready.isCompleted) _ready.complete();
    }, onError: (Object e) {
      onState?.call(LinkState.closed, 'Could not open the LAN ports: $e');
      if (!_ready.isCompleted) _ready.completeError(e);
    });
  }

  Future<void> _open() async {
    _http = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
    _http!.listen(_onHttp, onError: (_) {});
    _ws = await HttpServer.bind(InternetAddress.anyIPv4, wsPort);
    _ws!.listen(_onWsRequest, onError: (_) {});
    if (udpPort >= 0) {
      try {
        _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
        _udp!.listen(_onUdp);
      } on SocketException {
        _udp = null; // UDP is optional (another app may hold 4210)
      }
    }
  }

  @override
  void stop() {
    for (final c in _clients.values) {
      c.close();
    }
    _clients.clear();
    _http?.close(force: true);
    _ws?.close(force: true);
    _udp?.close();
    _http = _ws = null;
    _udp = null;
    onState?.call(LinkState.closed, 'stopped');
  }

  // --- packets ---------------------------------------------------------------------------

  String? _pendingAck;
  int? _pendingVid;

  /// Hands one packet to the intersection; returns its ACK text, or null for a bad packet
  /// (the firmware sends no ACK then). The intersection answers synchronously via [sendAck].
  String? _process(String raw) {
    Object? d;
    try {
      d = jsonDecode(raw);
    } on FormatException {
      d = null;
    }
    final id = d is Map && d['id'] is int ? d['id'] as int : 0;
    final ty = d is Map ? d['ty'] : null;
    if (!allowEmergency && ty is int && ty != 0) {
      refusedEmergency++;
      return null;
    }
    _pendingVid = id;
    _pendingAck = null;
    onPacket?.call(id, raw);
    final ack = _pendingAck;
    _pendingVid = null;
    _pendingAck = null;
    return ack;
  }

  @override
  void sendAck(int vid, String raw) {
    if (vid == _pendingVid) _pendingAck = raw;
  }

  @override
  void sendState(String raw) {
    _lastState = raw;
    for (final c in List.of(_clients.values)) {
      c.add(raw);
    }
  }

  // --- HTTP (port 8080 here, 80 on the ESP32) ----------------------------------------------

  void _cors(HttpResponse r) {
    r.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type');
  }

  Future<void> _onHttp(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'OPTIONS' && (path == '/api/vehicle' || path == '/api/mode')) {
        _cors(res);
        res.statusCode = HttpStatus.noContent;
      } else if (req.method == 'GET' && path == '/api/state') {
        _cors(res);
        _json(res, 200, stateNow?.call() ?? _lastState ?? '{}');
      } else if (req.method == 'GET' && path == '/api/mode') {
        _cors(res);
        final reply = onModeRequest?.call(req.uri.queryParameters['m'] ?? '') ?? '{"ok":false}';
        _json(res, reply.startsWith('{"ok":true') ? 200 : 400, reply);
      } else if (req.method == 'POST' && path == '/api/vehicle') {
        final body = await utf8.decoder.bind(req).join();
        final ack = _process(body);
        _cors(res);
        _json(res, ack == null ? 400 : 200, ack ?? '{"error":"bad packet"}');
      } else if (req.method == 'GET' && path == '/') {
        res.headers.contentType = ContentType.text;
        res.write('Digital V2I intersection (firmware v3 twin).\n'
            'GET /api/state, GET /api/mode?m=auto|fixed|adaptive, POST /api/vehicle; '
            'WebSocket on port $boundWsPort; UDP $boundUdpPort.\n');
      } else {
        res.statusCode = HttpStatus.notFound;
        res.headers.contentType = ContentType.text;
        res.write('not found');
      }
    } catch (_) {
      res.statusCode = HttpStatus.internalServerError;
    }
    await res.close();
  }

  void _json(HttpResponse res, int status, String body) {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(body);
  }

  // --- WebSocket (port 8081 here, 81 on the ESP32) -----------------------------------------

  Future<void> _onWsRequest(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    final id = _nextClient++;
    _clients[id] = ws;
    onWsClient?.call(id, true);
    final last = _lastState;
    if (last != null) ws.add(last);
    ws.listen(
      (data) {
        if (data is String) onWsText?.call(data);
      },
      onDone: () {
        _clients.remove(id);
        onWsClient?.call(id, false);
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  // --- UDP 4210 ------------------------------------------------------------------------------

  void _onUdp(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final udp = _udp;
    final dg = udp?.receive();
    if (udp == null || dg == null) return;
    // the firmware reads into a 256-byte buffer
    final bytes = dg.data.length > 255 ? dg.data.sublist(0, 255) : dg.data;
    final ack = _process(utf8.decode(bytes, allowMalformed: true));
    if (ack != null) udp.send(utf8.encode(ack), dg.address, dg.port);
  }

  /// IPv4 addresses of this phone that others on the network can use.
  static Future<List<String>> addresses() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      return [for (final i in ifs) for (final a in i.addresses) a.address];
    } catch (_) {
      return const [];
    }
  }
}
