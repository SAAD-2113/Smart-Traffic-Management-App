import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/core/config/app_config.dart';
import 'package:smart_traffic/core/storage/kv_store.dart';
import 'package:smart_traffic/core/utils/units.dart';
import 'package:smart_traffic/core/utils/validators.dart';

void main() {
  group('AppConfig', () {
    test('server address validation', () {
      expect(AppConfig.validateServerUrl('http://192.168.1.20:8000'), isNull);
      expect(AppConfig.validateServerUrl('https://traffic.example.org'), isNull);
      expect(AppConfig.validateServerUrl('192.168.1.20'), isNotNull);
      expect(AppConfig.validateServerUrl('ftp://x'), isNotNull);
      expect(AppConfig.validateServerUrl('http://x:8000/api'), isNotNull);
    });

    test('private addresses are recognised', () {
      expect(AppConfig.isPrivateHost('192.168.0.5'), isTrue);
      expect(AppConfig.isPrivateHost('10.0.2.2'), isTrue);
      expect(AppConfig.isPrivateHost('172.20.1.1'), isTrue);
      expect(AppConfig.isPrivateHost('8.8.8.8'), isFalse);
      expect(AppConfig.isPrivateHost('example.org'), isFalse);
    });

    test('installation id is created once and matches the server pattern', () async {
      final store = MemoryKeyValueStore();
      final a = await AppConfig.load(store);
      final b = await AppConfig.load(store);
      expect(a.installationId, b.installationId);
      expect(RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(a.installationId), isTrue);
    });

    test('settings persist', () async {
      final store = MemoryKeyValueStore();
      final config = await AppConfig.load(store);
      await config.setServerUrl('http://192.168.1.9:8000/');
      expect((await AppConfig.load(store)).apiBaseUrl, 'http://192.168.1.9:8000/api/v1');
    });
  });

  group('Units', () {
    test('m/s to km/h', () {
      expect(Units.kmh(10), 36);
      expect(Units.speed(11.8), '42 km/h');
      expect(Units.speed(null), '—');
    });

    test('formatting', () {
      expect(Units.distance(850), '850 m');
      expect(Units.distance(1500), '1.50 km');
      expect(Units.heading(92), '92° E');
      expect(Units.duration(125), '2 min 5 s');
    });
  });

  group('Validators mirror the backend', () {
    test('password rules', () {
      expect(Validators.password('short1'), isNotNull);
      expect(Validators.password('longenoughbutnodigit'), isNotNull);
      expect(Validators.password('Str0ngPassw0rd'), isNull);
    });

    test('phone and registration number', () {
      expect(Validators.optionalPhone(''), isNull);
      expect(Validators.optionalPhone('+923001234567'), isNull);
      expect(Validators.optionalPhone('03001234567'), isNotNull);
      expect(Validators.registrationNumber('lea 1234'), isNull);
      expect(Validators.registrationNumber('AB#12'), isNotNull);
    });
  });
}
