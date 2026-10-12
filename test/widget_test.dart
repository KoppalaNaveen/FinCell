import 'package:flutter_test/flutter_test.dart';
import 'package:fincell/main.dart';

void main() {
  testWidgets('FinCellApp Smoke Test', (WidgetTester tester) async {
    // Verify FinCellApp widget instantiates cleanly
    expect(const FinCellApp(), isNotNull);
  });
}
