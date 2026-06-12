// Basic smoke test: the app builds and shows its title.

import 'package:flutter_test/flutter_test.dart';

import 'package:cactus_example/main.dart';

void main() {
  testWidgets('App builds and shows the title', (WidgetTester tester) async {
    await tester.pumpWidget(const CactusApp());
    expect(find.text('Cactus Chat'), findsOneWidget);
  });
}
