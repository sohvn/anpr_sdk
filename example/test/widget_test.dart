import 'package:flutter_test/flutter_test.dart';
import 'package:anpr_sdk_example/main.dart';

void main() {
  testWidgets('ANPR demo app launches', (WidgetTester tester) async {
    await tester.pumpWidget(const AnprDemoApp());

    expect(find.byType(AnprDemoApp), findsOneWidget);
  });
}
