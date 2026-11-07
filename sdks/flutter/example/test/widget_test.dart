import 'package:flutter_test/flutter_test.dart';
import 'package:proxycept_logging_example/main.dart';

void main() {
  testWidgets('demo requires explicit key before network setup', (
    tester,
  ) async {
    await tester.pumpWidget(const LoggingExample());
    expect(find.text('Disposable ingest key'), findsOneWidget);
    expect(
      find.textContaining('Nothing is sent automatically'),
      findsOneWidget,
    );
  });
}
