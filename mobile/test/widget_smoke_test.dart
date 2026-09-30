import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/core/theme/app_theme.dart';
import 'package:smart_traffic/widgets/common.dart';

void main() {
  testWidgets('hold-to-confirm needs a sustained press', (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: HoldToConfirmButton(label: 'Hold', onConfirmed: () => confirmed++)),
    ));
    await tester.tap(find.text('Hold')); // a tap is not enough
    await tester.pumpAndSettle();
    expect(confirmed, 0);

    final short = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // one second: released too early
    }
    await short.up();
    await tester.pumpAndSettle();
    expect(confirmed, 0);

    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // frames keep coming while the finger is down
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(confirmed, 1);
  });

  testWidgets('congestion badge labels "no data" instead of hiding it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CongestionBadge('UNKNOWN'))));
    expect(find.text('Congestion: No data'), findsOneWidget);
  });
}
