import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/marquee_text.dart';

void main() {
  Widget host({
    bool reduced = false,
    String title = 'A long title that will not fit',
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(body: SizedBox(width: 120, child: MarqueeText(title))),
    ),
  );
  double offset(WidgetTester tester) => tester
      .widget<Transform>(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Transform),
        ),
      )
      .transform
      .storage[12];
  testWidgets('marquee rests five seconds, moves, wraps, and rests again', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(offset(tester), 0);
    await tester.pump(const Duration(seconds: 4));
    expect(offset(tester), 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(offset(tester), lessThan(0));
    await tester.pump(const Duration(seconds: 30));
    expect(offset(tester), 0);
    await tester.pump(const Duration(seconds: 4));
    expect(offset(tester), 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'short and reduced-motion titles stay static; changing title resets',
    (tester) async {
      await tester.pumpWidget(host(title: 'Short'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      await tester.pumpWidget(host(reduced: true));
      await tester.pump(const Duration(seconds: 8));
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(host(title: 'Another long song title'));
      await tester.pump();
      expect(offset(tester), 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
