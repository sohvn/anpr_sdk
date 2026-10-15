import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anpr_sdk_example/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ANPR scanner page displays the initial message', (
    WidgetTester tester,
  ) async {
    // Configure a mobile-sized test screen.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Build the scanner page without calling main().
    await tester.pumpWidget(const MaterialApp(home: ScanPage()));

    // Check that the initial instruction is visible.
    expect(find.text('Point the camera at a number plate'), findsOneWidget);

    // Check that the page has a Scaffold.
    expect(find.byType(Scaffold), findsOneWidget);

    // Check that the app displays the initial instruction,
    // rather than a detected number plate.
    expect(find.text('Scan'), findsNothing);
  });
}
