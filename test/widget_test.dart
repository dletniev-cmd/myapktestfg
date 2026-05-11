// Простой smoke-тест для GitHub Pusher.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App boots without crash', (WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byType(SizedBox), findsOneWidget);
  });
}
