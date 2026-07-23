import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/smooth_scroll_controller.dart';

void main() {
  testWidgets('interpolates and accumulates desktop wheel deltas', (
    tester,
  ) async {
    final controller = SmoothScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: ListView.builder(
            controller: controller,
            itemExtent: 80,
            itemCount: 30,
            itemBuilder: (_, index) => Text('Row $index'),
          ),
        ),
      ),
    );

    controller.position.pointerScroll(200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(200));

    controller.position.pointerScroll(120);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(320, 1));
  });
}
