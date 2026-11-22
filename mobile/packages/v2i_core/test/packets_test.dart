import 'package:test/test.dart';
import 'package:v2i_core/v2i_core.dart';

import 'bench.dart';

String pos(int id, {int seq = 1, String extra = '', double lat = 31.500111, double lon = 74.299996}) =>
    '{"t":"pos","id":$id,"ty":0,"lat":${cfix(lat, 6)},"lon":${cfix(lon, 6)},"spd":0.0,"hdg":181,"seq":$seq,"hw":"bench"$extra}';

void main() {
  group('pos packet (vehicle -> intersection)', () {
    test('same text and size as the firmware snprintf (README [TX] line)', () {
      final p = const PosPacket(
        id: 101,
        ty: 0,
        lat: 31.500111,
        lon: 74.299996,
        spd: 0.0,
        hdg: 181,
        seq: 25,
        hw: 'ESP32-S3',
        tl: 'N',
        rssi: -50,
      ).encode();
      expect(
        p,
        '{"t":"pos","id":101,"ty":0,"lat":31.500111,"lon":74.299996,"spd":0.0,"hdg":181,"seq":25,"hw":"ESP32-S3","tl":"N","rssi":-50}',
      );
      expect(packetBytes(p), 124);
      expect(fitsPacket(p), isTrue);
      // The README's "(121 B)" was measured on the PC bench with hw "ESP32"; the README then
      // renamed the boards in the printed lines ("ESP32-S3" is 3 characters longer).
      final bench = const PosPacket(
        id: 101,
        ty: 0,
        lat: 31.500111,
        lon: 74.299996,
        spd: 0.0,
        hdg: 181,
        seq: 25,
        hw: 'ESP32',
        tl: 'N',
        rssi: -50,
      ).encode();
      expect(packetBytes(bench), 121);
    });

    test('live GPS leaves out tl, rssi and (when unknown) hdg', () {
      final p = const PosPacket(id: 1001, ty: 1, lat: 31.5, lon: 74.3, spd: 12.3, seq: 7, hw: 'Pixel 8').encode();
      expect(p, '{"t":"pos","id":1001,"ty":1,"lat":31.500000,"lon":74.300000,"spd":12.3,"seq":7,"hw":"Pixel 8"}');
    });

    test('the intersection logs [CONN] and [RX] exactly like the firmware', () {
      final b = Bench();
      final ack = b.ic.processPacket(
        const PosPacket(
          id: 101,
          ty: 0,
          lat: 31.500111,
          lon: 74.299996,
          spd: 0.0,
          hdg: 181,
          seq: 25,
          hw: 'ESP32-S3',
          tl: 'N',
          rssi: -50,
        ).encode(),
      );
      expect(ack, isNotNull);
      // order inside processPacket(): [CONN], [RX  ], then modeWatch()
      expect(b.lines.sublist(b.lines.length - 3), [
        '[CONN] id=101 ESP32-S3 normal connected (1 vehicle(s)) - first vehicle',
        '[RX  ] id=101 normal ESP32-S3 lat=31.500111 lon=74.299996 spd=0.0 hdg=181 -> lane=N tl=N QUEUED d=12.4m brg=358',
        '[MODE] auto: vehicle data received (1 connected) -> ADAPTIVE from the next lane decision',
      ]);
    });
  });

  group('ACK (intersection -> vehicle)', () {
    test('README reply layout, with a lane', () {
      const a = AckPacket(id: 901, seq: 1, mode: 'fixed', lane: 'S', st: 'QUEUED', sig: 'R', rem: 78.2, pri: 0);
      expect(a.encode(), '{"t":"ack","id":901,"seq":1,"mode":"fixed","lane":"S","st":"QUEUED","sig":"R","rem":78.2,"pri":0}');
      final d = AckPacket.decode(a.encode())!;
      expect((d.id, d.seq, d.mode, d.lane, d.st, d.sig, d.pri), (901, 1, 'fixed', 'S', 'QUEUED', 'R', 0));
      expect(d.rem, closeTo(78.2, 1e-5));
    });

    test('without a lane: "lane":"-","sig":"-","rem":0', () {
      const a = AckPacket(id: 5, seq: 9, mode: 'adaptive', lane: '-', st: 'IGNORED', sig: '-', rem: 12.3, pri: 0);
      expect(a.encode(), '{"t":"ack","id":5,"seq":9,"mode":"adaptive","lane":"-","st":"IGNORED","sig":"-","rem":0,"pri":0}');
    });

    test('curl example sent 1 s into the first N green: S waits 29 + 4 + 30 + 4 = 67 s', () {
      final b = Bench();
      b.runUntil(3000);
      final ack = b.ic.processPacket(
        '{"t":"pos","id":901,"ty":0,"lat":31.499700,"lon":74.300000,"spd":0,"hdg":0,"seq":1,"hw":"laptop","tl":"S"}',
      );
      expect(ack, '{"t":"ack","id":901,"seq":1,"mode":"fixed","lane":"S","st":"QUEUED","sig":"R","rem":67.0,"pri":0}');
    });

    test('curl example while S is green: sig G, rem = green left', () {
      final b = Bench();
      b.runUntil(95800); // S green 70..100 s
      final ack = b.ic.processPacket(
        '{"t":"pos","id":901,"ty":0,"lat":31.499700,"lon":74.300000,"spd":0,"hdg":0,"seq":1,"hw":"laptop","tl":"S"}',
      );
      expect(ack, '{"t":"ack","id":901,"seq":1,"mode":"fixed","lane":"S","st":"QUEUED","sig":"G","rem":4.2,"pri":0}');
    });

    test('ty:1 gives pri:1', () {
      final b = Bench();
      final ack = b.ic.processPacket(
        '{"t":"pos","id":902,"ty":1,"lat":31.499700,"lon":74.300000,"spd":0,"hdg":0,"seq":1,"hw":"laptop","tl":"S"}',
      );
      expect(ack, endsWith('"pri":1}'));
    });
  });

  group('[MISMATCH] (the tl field is only checked, never used)', () {
    test('README: computed lane E but test data says N', () {
      final b = Bench();
      b.runUntil(3000); // lastMismatchLog starts at 0: the firmware logs only once millis() >= 2000
      final ack = b.ic.processPacket(
        '{"t":"pos","id":902,"ty":0,"lat":31.500000,"lon":74.300600,"hdg":270,"seq":1,"hw":"laptop","tl":"N"}',
      );
      expect(ack, contains('"lane":"E"'));
      expect(b.lines, contains('[MISMATCH] id=902 computed lane E but test data says N (brg=90 d=56.9m hdg=270)'));
    });

    test('at most one [MISMATCH] per vehicle per 2 s', () {
      final b = Bench();
      b.runUntil(3000);
      for (var i = 0; i < 9; i++) {
        b.ic.processPacket('{"t":"pos","id":902,"lat":31.500000,"lon":74.300600,"hdg":270,"seq":${i + 1},"hw":"x","tl":"N"}');
        b.run(500);
      }
      expect(b.lines.where((l) => l.startsWith('[MISMATCH]')), hasLength(3)); // 3.0, 5.0, 7.0 s
    });
  });

  group('bad packets', () {
    test('[RX! ] lines, counters, no ACK', () {
      final b = Bench();
      final long = 'x' * 120;
      for (final p in [
        'hello',
        '{"t":"ack","id":1}',
        long,
        '{"t":"pos","lat":31.5,"lon":74.3}',
        '{"t":"pos","id":0,"lat":31.5,"lon":74.3}',
        '{"t":"pos","id":65536,"lat":31.5,"lon":74.3}',
        '{"t":"pos","id":7,"lat":31.5}',
        '{"t":"pos","id":7.0,"lat":31.5,"lon":74.3}',
      ]) {
        expect(b.ic.processPacket(p), isNull, reason: p);
      }
      expect(b.ic.pktBad, 8);
      expect(b.ic.pktRx, 0);
      final bad = b.lines.where((l) => l.startsWith('[RX! ]')).toList();
      expect(bad[0], '[RX! ] bad packet: hello');
      expect(bad[2], '[RX! ] bad packet: ${'x' * 80}', reason: '%.80s');
      expect(bad[3], '[RX! ] packet without id/lat/lon: {"t":"pos","lat":31.5,"lon":74.3}');
      expect(bad[7], startsWith('[RX! ] packet without id/lat/lon'), reason: 'id must be an integer');
    });

    test('vehicle table full at MAX_VEH = 16 (the packet still counts in rx)', () {
      final b = Bench();
      for (var id = 1; id <= 16; id++) {
        expect(b.ic.processPacket(pos(id)), isNotNull);
      }
      expect(b.ic.processPacket(pos(17)), isNull);
      expect(b.lines.last, '[RX! ] vehicle table full');
      expect(b.ic.pktRx, 17);
      expect(b.ic.pktBad, 0);
    });
  });

  group('per-vehicle bookkeeping', () {
    test('lost packets counted from seq gaps; a restart (lower seq) counts nothing', () {
      final b = Bench();
      for (final s in [1, 2, 5, 6, 1, 2]) {
        b.ic.processPacket(pos(101, seq: s));
      }
      b.ic.processPacket('{"t":"pos","id":101,"lat":31.500111,"lon":74.299996}'); // no seq: lastSeq kept
      final v = b.ic.findVeh(101)!;
      expect((v.pkts, v.lost, v.lastSeq), (7, 2, 2));
    });

    test('defaults: missing spd = 0, missing hdg = -1 (no heading), hw "?" and cut to 11 chars, ty != 0 is emergency', () {
      final b = Bench();
      b.ic.processPacket('{"t":"pos","id":5,"lat":31.5004,"lon":74.3}');
      b.ic.processPacket('{"t":"pos","id":6,"ty":2,"lat":31.5004,"lon":74.3,"hw":"ABCDEFGHIJKLMNOP"}');
      b.ic.processPacket('{"t":"pos","id":7,"ty":"1","lat":31.5004,"lon":74.3,"spd":"fast"}');
      final v5 = b.ic.findVeh(5)!, v6 = b.ic.findVeh(6)!, v7 = b.ic.findVeh(7)!;
      expect((v5.spd, v5.hdg, v5.hw, v5.type), (0.0, -1.0, '?', VT_NORMAL));
      expect((v6.hw, v6.type), ('ABCDEFGHIJK', VT_EMERGENCY));
      expect((v7.type, v7.spd), (VT_NORMAL, 0.0), reason: 'wrong JSON types fall back to the default, like ArduinoJson');
      expect(v5.st, V2IState.queued, reason: 'no heading: the first packet counts as getting closer (44.5 m, spd 0)');
    });

    test('[LOST] after 3 s of silence, with the firmware layout', () {
      final b = Bench();
      b.ic.processPacket(pos(101, extra: ',"tl":"N"'));
      b.runUntil(5000);
      expect(
        b.lines.where((l) => l.startsWith('[LOST]')).single,
        '[LOST] id=101 bench - no packet for 3.0s (pkts=1 lost=0) -> removed, 0 vehicle(s) left',
      );
      expect(b.ic.connectedVehicles(), 0);
    });
  });
}
