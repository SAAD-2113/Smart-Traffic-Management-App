import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/digital/transport/cloud_relay.dart';
import 'package:smart_traffic/digital/transport/links.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A WebSocket the test plays the server of.
class FakeSocket with StreamChannelMixin implements WebSocketChannel {
  final toClient = StreamController<dynamic>();
  final fromClient = <Map<String, dynamic>>[];
  int? _code;
  String? _reason;
  late final _sink = _Sink(this);

  @override
  Stream get stream => toClient.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => _code;

  @override
  String? get closeReason => _reason;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();

  void serverSend(Map<String, dynamic> m) => toClient.add(jsonEncode(m));

  Future<void> serverClose(int code, [String? reason]) async {
    _code = code;
    _reason = reason;
    await toClient.close();
  }
}

class _Sink implements WebSocketSink {
  _Sink(this.s);
  final FakeSocket s;

  @override
  void add(dynamic data) => s.fromClient.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future close([int? closeCode, String? closeReason]) async {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {}

  @override
  Future get done => Future.value();
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late List<FakeSocket> sockets;
  late int refreshes;
  late String token;

  RelaySocket socket({bool refreshOk = true}) => RelaySocket(
        uri: Uri.parse('wss://server.example/api/v1/v2i/ws'),
        sessionId: 'S1',
        accessToken: () => token,
        refreshToken: () async {
          refreshes++;
          token = 'T${refreshes + 1}';
          return refreshOk;
        },
        connect: (uri) {
          final s = FakeSocket();
          sockets.add(s);
          return s;
        },
        retryDelay: const Duration(milliseconds: 20),
      );

  setUp(() {
    sockets = [];
    refreshes = 0;
    token = 'T1';
  });

  test('the token goes in the first message, never in the URL; hello = online', () async {
    final link = CloudVehicleLink(socket());
    final states = <LinkState>[];
    link.onState = (s, _) => states.add(s);
    bool? intersection;
    link.onIntersection = (o) => intersection = o;
    link.start();
    await pump();
    expect(sockets.single.fromClient.first, {'type': 'auth', 'accessToken': 'T1', 'sessionId': 'S1'});
    expect(link.socket.uri.query, isEmpty);
    link.send('{"t":"pos"}');
    expect(sockets.single.fromClient, hasLength(1), reason: 'nothing is sent before hello');
    sockets.single.serverSend({'k': 'hello', 'as': 'vehicle', 'vid': 1001, 'intersectionOnline': true});
    await pump();
    expect(states, [LinkState.connecting, LinkState.online]);
    expect(intersection, isTrue);
    link.send('{"t":"pos","id":1001}');
    link.sendRtt(42);
    expect(sockets.single.fromClient.sublist(1), [
      {'k': 'pos', 'raw': '{"t":"pos","id":1001}'},
      {'k': 'rtt', 'ms': 42},
    ]);
    String? ack;
    link.onAck = (raw) => ack = raw;
    sockets.single.serverSend({'k': 'ack', 'raw': '{"t":"ack","id":1001}'});
    String? err;
    link.onError = (c, _) => err = c;
    sockets.single.serverSend({'k': 'err', 'code': 'EMERGENCY_NOT_AUTHORIZED', 'message': 'x'});
    await pump();
    expect(ack, '{"t":"ack","id":1001}');
    expect(err, 'EMERGENCY_NOT_AUTHORIZED');
    link.stop();
  });

  test('intersection side: pos, rtt and member messages; ack and state go out', () async {
    final link = CloudIntersectionLink(socket());
    final got = <String>[];
    link
      ..onPacket = ((vid, raw) => got.add('pos $vid $raw'))
      ..onRtt = ((vid, ms) => got.add('rtt $vid $ms'))
      ..onMember = ((vid, on, em) => got.add('member $vid $on $em'));
    link.start();
    await pump();
    final s = sockets.single;
    s.serverSend({'k': 'hello', 'as': 'intersection'});
    s.serverSend({'k': 'members', 'vehicles': [{'vid': 1001, 'emergency': false}]});
    s.serverSend({'k': 'pos', 'vid': 1001, 'raw': 'P'});
    s.serverSend({'k': 'rtt', 'vid': 1001, 'ms': 80});
    s.serverSend({'k': 'member', 'vid': 1002, 'online': true, 'emergency': true});
    await pump();
    expect(got, ['member 1001 true false', 'pos 1001 P', 'rtt 1001 80', 'member 1002 true true']);
    link.sendAck(1001, 'A');
    link.sendState('S');
    expect(s.fromClient.sublist(1), [
      {'k': 'ack', 'to': 1001, 'raw': 'A'},
      {'k': 'state', 'raw': 'S'},
    ]);
    link.stop();
  });

  test('token expired (4401): refresh, then reconnect with the new token', () async {
    final link = CloudVehicleLink(socket());
    link.start();
    await pump();
    sockets.first.serverSend({'k': 'hello'});
    await pump();
    await sockets.first.serverClose(4401, 'TOKEN_EXPIRED');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(refreshes, 1);
    expect(sockets, hasLength(2));
    expect(sockets.last.fromClient.first['accessToken'], 'T2');
    link.stop();
  });

  test('a dropped connection is retried; a closed session ends the link for good', () async {
    final link = CloudVehicleLink(socket());
    final states = <(LinkState, String?)>[];
    link.onState = (s, r) => states.add((s, r));
    link.start();
    await pump();
    await sockets.first.serverClose(1006);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(sockets, hasLength(2), reason: 'retried after 20 ms');
    await sockets.last.serverClose(4410, 'SESSION_CLOSED');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(sockets, hasLength(2), reason: 'no retry after the session was closed');
    expect(states.last, (LinkState.closed, 'The session was closed.'));
  });

  test('refresh refused on 4401: closed, sign in again', () async {
    final link = CloudVehicleLink(socket(refreshOk: false));
    final states = <(LinkState, String?)>[];
    link.onState = (s, r) => states.add((s, r));
    link.start();
    await pump();
    await sockets.first.serverClose(4401);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(states.last, (LinkState.closed, 'Please sign in again.'));
    expect(sockets, hasLength(1));
  });
}
