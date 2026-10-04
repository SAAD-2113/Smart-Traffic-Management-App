import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/core/theme/app_theme.dart';
import 'package:smart_traffic/data/models/control.dart';
import 'package:smart_traffic/data/models/traffic.dart';
import 'package:smart_traffic/widgets/signal_widgets.dart';

final _now = DateTime.utc(2026, 10, 4, 12, 0, 0);

Map<String, dynamic> _timing(String phase, List<String> approaches, double green, double cycle) => {
      'phase': phase,
      'approaches': approaches,
      'greenS': green,
      'yellowS': 3.0,
      'allRedS': 2.0,
      'redS': cycle - green - 3.0,
    };

Map<String, dynamic> _control({
  String mode = 'ADAPTIVE',
  String reason = 'HIGH_CONGESTION',
  String headline = 'High congestion detected',
  Map<String, dynamic>? pending,
}) =>
    {
      'policy': 'AUTO',
      'mode': mode,
      'baseMode': mode,
      'reason': reason,
      'headline': headline,
      'detail': 'Average congestion is HIGH (on average 42 vehicles at 12 km/h over the last 60 s).',
      'since': _now.subtract(const Duration(minutes: 2)).toIso8601String(),
      'pending': pending,
      'traffic': {
        'congestionLevel': 'HIGH',
        'averagedLevel': 'HIGH',
        'dataQuality': 'HIGH',
        'vehicleCount': 42,
        'windowS': 60,
        'windowVehicleCount': 42,
        'windowAvgSpeedMps': 12 / 3.6,
        'windowAvgWaitingTimeS': 20,
      },
      'fixedTiming': [
        _timing('Northbound+Southbound', ['Northbound', 'Southbound'], 30, 66),
        _timing('Eastbound+Westbound', ['Eastbound', 'Westbound'], 26, 66),
      ],
      'fixedCycleS': 66,
      'activeTiming': [
        _timing('Northbound+Southbound', ['Northbound', 'Southbound'], 48, 76),
        _timing('Eastbound+Westbound', ['Eastbound', 'Westbound'], 18, 76),
      ],
      'activeCycleS': 76,
      'algorithm': mode == 'ADAPTIVE' ? 'DEMAND_PROPORTIONAL' : 'FIXED_TIME',
    };

Map<String, dynamic> _display() => {
      'source': 'VIRTUAL',
      'virtual': true,
      'phaseName': 'Northbound+Southbound',
      'state': 'GREEN',
      'remainingS': 12.0,
      'mode': 'ADAPTIVE',
      'reportedAt': _now.toIso8601String(),
      'heads': [
        {'approach': 'Northbound', 'bearingDeg': 0.0, 'light': 'GREEN'},
        {'approach': 'Southbound', 'bearingDeg': 180.0, 'light': 'GREEN'},
        {'approach': 'Eastbound', 'bearingDeg': 90.0, 'light': 'RED'},
        {'approach': 'Westbound', 'bearingDeg': 270.0, 'light': 'RED'},
      ],
    };

IntersectionTraffic _item({Map<String, dynamic>? control}) => IntersectionTraffic({
      'id': 'x',
      'code': 'I2',
      'name': 'Main St & 2nd Ave',
      'control': control ?? _control(),
      'displaySignal': _display(),
    });

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(8), child: child))),
    );

void main() {
  group('control models', () {
    test('shortPhase abbreviates paired compass phases only', () {
      expect(shortPhase('Northbound+Southbound'), 'N/S');
      expect(shortPhase('Eastbound+Westbound'), 'E/W');
      expect(shortPhase('Left turns'), 'Left turns');
      expect(shortPhase('Northbound'), 'Northbound');
    });

    test('remaining time counts down on the server clock and stops at zero', () {
      final d = SignalDisplay(_display());
      expect(d.remainingAt(_now), 12);
      expect(d.remainingAt(_now.add(const Duration(seconds: 5))), 7);
      expect(d.remainingAt(_now.add(const Duration(seconds: 30))), 0);
    });

    test('adaptive and emergency count as changed timing', () {
      expect(ControlStatus(_control()).timingChanged, isTrue);
      expect(ControlStatus(_control(mode: 'FIXED_TIME', reason: 'NORMAL_TRAFFIC')).timingChanged, isFalse);
      expect(ControlStatus(_control(mode: 'EMERGENCY_PRIORITY')).isEmergency, isTrue);
    });
  });

  testWidgets('mode badge always shows a label, not colour alone', (tester) async {
    await tester.pumpWidget(_wrap(const Column(children: [
      ModeBadge('FIXED_TIME'),
      ModeBadge('ADAPTIVE'),
      ModeBadge('EMERGENCY_PRIORITY'),
    ])));
    expect(find.text('FIXED-TIME'), findsOneWidget);
    expect(find.text('ADAPTIVE'), findsOneWidget);
    expect(find.text('EMERGENCY'), findsOneWidget);
  });

  testWidgets('control card shows the mode, the reason, the traffic and the calculated green', (tester) async {
    await tester.pumpWidget(_wrap(ControlCard(item: _item(), serverNow: () => _now)));
    expect(find.text('ADAPTIVE'), findsOneWidget);
    expect(find.text('High congestion detected'), findsOneWidget);
    expect(find.text('42'), findsOneWidget); // vehicles
    expect(find.text('12'), findsWidgets); // km/h (and the countdown)
    expect(find.text('Active timing (calculated)'), findsOneWidget);
    expect(find.textContaining('Green 48 s'), findsOneWidget);
    expect(find.textContaining('+18 vs fixed'), findsOneWidget);
    expect(find.textContaining('virtual controller'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // let the tickers run once
  });

  testWidgets('control card announces a pending switch', (tester) async {
    final control = _control(
      mode: 'FIXED_TIME',
      reason: 'CONGESTION_DETECTED',
      headline: 'Congestion building',
      pending: {'toMode': 'ADAPTIVE', 'inS': 12.4, 'condition': 'if congestion persists'},
    );
    await tester.pumpWidget(_wrap(ControlCard(item: _item(control: control), serverNow: () => _now)));
    expect(find.text('Congestion building'), findsOneWidget);
    expect(find.text('Switching to adaptive in 13 s if congestion persists'), findsOneWidget);
    expect(find.text('Signal timing (fixed plan)'), findsOneWidget);
  });

  testWidgets('map marker draws one head per approach on the side traffic arrives from', (tester) async {
    await tester.pumpWidget(_wrap(Center(child: IntersectionSignalMarker(item: _item(), serverNow: () => _now))));
    final marker = tester.getCenter(find.byType(IntersectionSignalMarker));
    final heads = find.descendant(of: find.byType(IntersectionSignalMarker), matching: find.byType(Transform));
    expect(heads, findsNWidgets(4));
    // The translated head is the Transform's child; measure that, not the Transform itself.
    Offset head(int i) => tester.getCenter(find.descendant(of: heads.at(i), matching: find.byType(Container)).first);
    final hub = head(0).dx; // north and south heads share the hub's x
    // Northbound traffic (bearing 0) arrives from the south: its head is below the southbound one.
    expect(head(0).dy, greaterThan(head(1).dy));
    expect(head(0).dx, closeTo(hub, 0.5));
    // Eastbound traffic arrives from the west: its head is left of the westbound one.
    expect(head(2).dx, lessThan(head(3).dx));
    expect(head(2).dy, closeTo(head(3).dy, 0.5));
    expect(marker.dx, closeTo(hub, 0.5));
    expect(find.text('I2'), findsOneWidget);
  });
}
