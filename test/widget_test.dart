import 'package:flutter_test/flutter_test.dart';
import 'package:catchme/main.dart';

void main() {
  testWidgets('App starts with radar screen', (WidgetTester tester) async {
    await tester.pumpWidget(const CatchMeApp());
    expect(find.text('Radar'), findsOneWidget);
  });
}
