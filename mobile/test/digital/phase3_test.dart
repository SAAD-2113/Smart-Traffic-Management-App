import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_traffic/core/auth/token_store.dart';
import 'package:smart_traffic/core/config/app_config.dart';
import 'package:smart_traffic/core/network/api_client.dart';
import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/core/theme/app_theme.dart';
import 'package:smart_traffic/digital/data/v2i_models.dart';
import 'package:smart_traffic/digital/data/v2i_repository.dart';
import 'package:smart_traffic/digital/export/session_export.dart';
import 'package:smart_traffic/digital/intersection/digital_intersection.dart';
import 'package:smart_traffic/digital/transport/loopback.dart';
import 'package:smart_traffic/digital/ui/digital_app.dart';
import 'package:smart_traffic/digital/ui/intersection_screen.dart';
import 'package:smart_traffic/hardware/platform/hardware_platform.dart';
import 'package:smart_traffic/services/location_service.dart';
import 'package:v2i_core/v2i_core.dart' as v2i;

import 'digital_ui_test.dart' show FakeRepo, FakeServices;

/// Saves "files" in memory, like the Android bridge would to Downloads.
class SavingPlatform extends HardwarePlatform {
  const SavingPlatform(this.files);
  final Map<String, String> files;

  @override
  bool get supportsSavingFiles => true;

  @override
  Future<String?> saveToDownloads(String name, String mime, Uint8List bytes) async {
    files[name] = utf8.decode(bytes);
    return 'Downloads/DigitalV2I/$name';
  }

  @override
  Future<String?> deviceName() async => 'TestPhone X1 (Android 14)';

  @override
  Future<void> keepScreenOn(bool on) async {}
}

class UploadRepo extends FakeRepo {
  UploadRepo(super.api);
  final uploads = <String, String>{};

  @override
  Future<void> uploadExport(String sessionId, {required String filename, required String contentType, required String content}) async =>
      uploads[filename] = content;
}

void main() {
  test('injector: presets keep their firmware ids, custom vehicles get 501+, all are recorded', () {
    final clock = v2i.FakeClock(0);
    final j = DigitalIntersection(name: 'Gate', centerLat: 31.5, centerLon: 74.3, link: LoopbackHub().intersection(), clock: clock, useTimer: false)
      ..start();
    j.inject(v2i.PRESETS[0]);
    j.inject(v2i.PRESETS[4]); // 201, emergency, after 30 s
    final customId = v2i.nextCustomId(j.injectedIds)!;
    j.inject(v2i.VehicleSpec(id: customId, type: v2i.VT_NORMAL, arm: 1, slot: 0, startDist: 100, kmh: 30, delayS: 0));
    expect(customId, 501);
    expect(() => j.inject(v2i.PRESETS[0]), throwsStateError);
    for (var t = 0; t < 60000; t += 10) {
      clock.advance(10);
      j.step();
    }
    expect(j.controller.findVeh(101)!.hw, 'inject');
    expect(j.controller.findVeh(201)!.type, v2i.VT_EMERGENCY);
    expect(j.controller.findVeh(501), isNotNull);
    expect(j.recorder.recording.samples.map((s) => s.id).toSet(), {101, 201, 501});
    expect(j.recorder.recording.snapshots.length, inInclusiveRange(59, 61));
    expect(j.log.lines.map((l) => l.text), contains(startsWith('[APP ] test injector: vehicle 201 (emergency, arm W')));
    j.removeInjected(101);
    for (var t = 0; t < 4000; t += 10) {
      clock.advance(10);
      j.step();
    }
    expect(j.controller.findVeh(101), isNull, reason: 'switched off: removed by the controller after 3 s');
    j.dispose();
  });

  test('export: four labelled files saved to Downloads and copied to the server', () async {
    final clock = v2i.FakeClock(0);
    final j = DigitalIntersection(name: 'Campus gate', centerLat: 31.5, centerLon: 74.3, link: LoopbackHub().intersection(), clock: clock, useTimer: false)
      ..start();
    j.inject(v2i.PRESETS[0]);
    for (var t = 0; t < 30000; t += 10) {
      clock.advance(10);
      j.step();
    }
    final r = j.recorder.recording;
    final label = v2i.ExportLabel(device: 'TestPhone X1 (Android 14)', date: DateTime(2026, 11, 22, 10, 30), session: 'Campus gate');
    final files = sessionFiles(r, v2i.computeMetrics(r), label);
    expect(files.map((f) => f.name), [
      'v2i_Campus-gate_20261122-1030_events.log',
      'v2i_Campus-gate_20261122-1030_snapshots.csv',
      'v2i_Campus-gate_20261122-1030_vehicles.csv',
      'v2i_Campus-gate_20261122-1030_metrics.csv',
    ]);
    final saved = <String, String>{};
    final config = await AppConfig.load(MemoryKeyValueStore());
    final repo = UploadRepo(ApiClient(config, TokenStore()));
    final out = await exportFiles(files, platform: SavingPlatform(saved), repo: repo, sessionId: 'S1');
    expect(out.saved, hasLength(4));
    expect(out.uploaded, hasLength(4));
    expect(out.problems, isEmpty);
    for (final text in [...saved.values, ...repo.uploads.values]) {
      expect(text, contains('digital simulation, measured on TestPhone X1 (Android 14) on 2026-11-22 10:30'));
    }
    expect(out.summary, startsWith('Saved 4 file(s) to Downloads/DigitalV2I.'));
    j.dispose();
  });

  testWidgets('intersection screen: inject a preset, open metrics, run Fixed vs Adaptive', (tester) async {
    tester.view.physicalSize = const Size(1280, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryKeyValueStore();
    final config = await AppConfig.load(store);
    final repo = UploadRepo(ApiClient(config, TokenStore()));
    final saved = <String, String>{};
    final session = HostedSession(
        id: 'S1', name: 'Gate', joinCode: 'ABC234', centerLat: 31.5, centerLon: 74.3, status: 'OPEN', createdAt: DateTime.utc(2026));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: config),
        Provider<V2IRepository>.value(value: repo),
        Provider<DigitalServices>.value(value: FakeServices(repo, LoopbackHub())),
        Provider<HardwarePlatform>.value(value: SavingPlatform(saved)),
        Provider(create: (_) => LocationService()),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: IntersectionScreen(session: session)),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('preset-1')));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Vehicles (1)'), findsOneWidget);
    expect(find.text('inject'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('open-metrics')));
    await tester.pumpAndSettle();
    expect(find.text('Metrics'), findsOneWidget);
    expect(find.textContaining('Digital simulation, measured on TestPhone X1 (Android 14)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('export')));
    await tester.pumpAndSettle();
    expect(saved.keys, hasLength(4));
    expect(repo.uploads.keys, hasLength(4));

    await tester.tap(find.byKey(const ValueKey('open-comparison')));
    await tester.pumpAndSettle();
    expect(find.text('Fixed vs Adaptive'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('cmp-minutes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 min simulated').last);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('cmp-run')));
      for (var i = 0; i < 200 && find.byKey(const ValueKey('cmp-table')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('cmp-table')), findsOneWidget);
    expect(find.text('FIXED (forced)'), findsOneWidget);
    expect(find.text('AUTO'), findsOneWidget);
    expect(find.textContaining('real time, measured on TestPhone X1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
