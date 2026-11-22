import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/digital/data/v2i_models.dart';
import 'package:smart_traffic/digital/intersection/digital_intersection.dart';
import 'package:smart_traffic/digital/transport/http_vehicle.dart';
import 'package:smart_traffic/digital/transport/lan_server.dart';
import 'package:smart_traffic/digital/vehicle/digital_vehicle.dart';
import 'package:smart_traffic/hardware/model/frame.dart';
import 'package:smart_traffic/hardware/monitor.dart';
import 'package:smart_traffic/hardware/settings.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../hardware/fakes.dart' show NoPlatform;

const curl = '{"t":"pos","id":901,"ty":0,"lat":31.499700,"lon":74.300000,"spd":0,"hdg":0,"seq":1,"hw":"laptop","tl":"S"}';

void main() {
  late LanIntersectionLink lan;
  late DigitalIntersection j;
  late Uri http0;

  setUp(() async {
    lan = LanIntersectionLink(httpPort: 0, wsPort: 0, udpPort: 0);
    j = DigitalIntersection(name: 'LAN junction', centerLat: v2i.CENTER_LAT, centerLon: v2i.CENTER_LON, link: lan)..start();
    await lan.ready;
    http0 = Uri.parse('http://127.0.0.1:${lan.boundHttpPort}');
  });

  tearDown(() => j.dispose());

  test('POST /api/vehicle answers with the firmware ACK; bad packets get 400; emergency needs the host\'s OK', () async {
    final r = await http.post(http0.replace(path: '/api/vehicle'), body: curl);
    expect(r.statusCode, 200);
    expect(r.body, matches(RegExp(r'^\{"t":"ack","id":901,"seq":1,"mode":"fixed","lane":"S","st":"QUEUED","sig":"[GYR]","rem":\d+\.\d,"pri":0\}$')));
    expect(r.headers['access-control-allow-origin'], '*');
    final bad = await http.post(http0.replace(path: '/api/vehicle'), body: 'hello');
    expect((bad.statusCode, bad.body), (400, '{"error":"bad packet"}'));
    expect(j.log.lines.map((l) => l.text), contains('[RX! ] bad packet: hello'));

    final emerg = curl.replaceFirst('"ty":0', '"ty":1').replaceFirst('"id":901', '"id":902');
    expect((await http.post(http0.replace(path: '/api/vehicle'), body: emerg)).statusCode, 400);
    expect(lan.refusedEmergency, 1);
    lan.allowEmergency = true;
    final ok = await http.post(http0.replace(path: '/api/vehicle'), body: emerg);
    expect(ok.statusCode, 200);
    expect(ok.body, endsWith('"pri":1}'));
  });

  test('GET /api/state is the state JSON ("v":2 first); GET /api/mode sets the mode like the firmware', () async {
    final s = await http.get(http0.replace(path: '/api/state'));
    expect(s.body, startsWith('{"v":2,"t":"state",'));
    expect(parseFrame(s.body), isA<V3StateFrame>());
    final m = await http.get(http0.replace(path: '/api/mode', queryParameters: {'m': 'fixed'}));
    expect((m.statusCode, m.body), (200, '{"ok":true,"requested_mode":"fixed","mode":"fixed","target_mode":"fixed"}'));
    expect(j.log.lines.map((l) => l.text), contains(contains("requested=fixed (from web /api/mode)")));
    final bad = await http.get(http0.replace(path: '/api/mode', queryParameters: {'m': 'turbo'}));
    expect((bad.statusCode, bad.body), (400, '{"ok":false,"requested_mode":"fixed","mode":"fixed","target_mode":"fixed"}'));
  });

  test('WebSocket: the state every 500 ms; mode commands as on port 81', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${lan.boundWsPort}/');
    final frames = <String>[];
    final sub = ws.listen((d) => frames.add(d as String));
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(frames.length, inInclusiveRange(2, 4));
    expect(frames.every((f) => f.startsWith('{"v":2,"t":"state",')), isTrue);
    ws.add('adaptive\n');
    ws.add('not json');
    ws.add('{"mode":"warp"}');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final lines = j.log.lines.map((l) => l.text).toList();
    expect(lines, contains(startsWith('[MODE] requested=adaptive (from WebSocket)')));
    expect(lines, contains('[APP ] unknown WebSocket command: {"mode":"warp"}'));
    expect(lines.where((l) => l.contains('not json')), isEmpty, reason: 'the firmware ignores it');
    expect(lines, contains('[APP ] WebSocket client 0 connected'));
    await sub.cancel();
    await ws.close();
  });

  test('UDP 4210: the ACK goes back to the sender', () async {
    final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = Completer<String>();
    sock.listen((e) {
      if (e == RawSocketEvent.read) {
        final dg = sock.receive();
        if (dg != null && !got.isCompleted) got.complete(utf8.decode(dg.data));
      }
    });
    sock.send(utf8.encode(curl), InternetAddress.loopbackIPv4, lan.boundUdpPort);
    expect(await got.future.timeout(const Duration(seconds: 3)), startsWith('{"t":"ack","id":901,"seq":1,'));
    sock.close();
  });

  test('a phone vehicle over HTTP (LAN / hardware bridge): ACKs and measured RTT', () async {
    final session = JoinedSession(
        sessionId: 'lan', name: 'LAN junction', centerLat: v2i.CENTER_LAT, centerLon: v2i.CENTER_LON, vehicleId: 1001, emergency: false);
    final v = DigitalVehicle(session: session, link: HttpVehicleLink(http0), source: const SimulatedDrive(arm: 0))..start();
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    expect(v.acksReceived, greaterThanOrEqualTo(4));
    expect(v.rttSamples, isNotEmpty);
    expect(v.lane, 'N');
    expect(j.controller.findVeh(1001)!.tl, 0, reason: 'simulated drive sends tl = its arm');
    // ignore: avoid_print
    print('LAN (localhost) RTT samples: ${v.rttSamples}');
    v.dispose();
  });

  test('the Hardware-mode dashboard shows the digital intersection over its own WebSocket', () async {
    final settings = HardwareSettings(MemoryKeyValueStore());
    await settings.setAddress('127.0.0.1', lan.boundWsPort);
    final m = HardwareMonitor(settings: settings, platform: const NoPlatform())..start();
    for (var i = 0; i < 30 && !m.isV3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(m.isV3, isTrue);
    expect(m.intersectionLabel, 'LAN junction');
    expect(m.v3!.controller, 'Digital Intersection (Flutter)');
    expect(m.laneDisplay('N'), isNotNull);
    m.dispose();
  });
}
