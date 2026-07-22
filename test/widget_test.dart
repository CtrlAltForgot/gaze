import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/main.dart';

void main() {
  testWidgets('shows the desktop shell verification message', (tester) async {
    await tester.pumpWidget(const GazeApp());

    expect(find.text('gaze'), findsOneWidget);
    expect(find.text('The desktop shell is running.'), findsOneWidget);
  });
}
