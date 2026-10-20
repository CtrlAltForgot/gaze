import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/design/gaze_motion.dart';

void main() {
  testWidgets(
    'page transitions preserve scroll state and block outgoing input',
    (tester) async {
      var index = 0;
      var oldTaps = 0;
      late StateSetter update;
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return GazePageStack(
                index: index,
                children: [
                  Column(
                    children: [
                      TextButton(
                        onPressed: () => oldTaps++,
                        child: const Text('Old action'),
                      ),
                      Expanded(
                        child: ListView.builder(
                          controller: scroll,
                          itemCount: 100,
                          itemExtent: 40,
                          itemBuilder: (_, i) => Text('Row $i'),
                        ),
                      ),
                    ],
                  ),
                  const Center(child: Text('Second page')),
                ],
              );
            },
          ),
        ),
      );
      scroll.jumpTo(400);
      await tester.pump();
      final originalPosition = scroll.position;
      update(() => index = 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final oldAction = find.text('Old action');
      expect(oldAction, findsOneWidget); // still painting its exit
      await tester.tap(oldAction, warnIfMissed: false);
      expect(oldTaps, 0);
      expect(
        find
            .ancestor(of: oldAction, matching: find.byType(Opacity))
            .evaluate()
            .any(
              (e) =>
                  (e.widget as Opacity).opacity > 0 &&
                  (e.widget as Opacity).opacity < 1,
            ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(oldAction, findsNothing);
      update(() => index = 0);
      await tester.pumpAndSettle();
      expect(identical(scroll.position, originalPosition), isTrue);
      expect(scroll.offset, 400);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a closing panel retains content, reverses quickly, then releases it',
    (tester) async {
      var open = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    GazePanel(
                      open: open,
                      width: 240,
                      child: open ? const Text('Panel content') : null,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      update(() => open = true);
      await tester.pump();
      await tester.pumpAndSettle();
      update(() => open = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Panel content'), findsOneWidget);
      update(() => open = true);
      await tester.pumpAndSettle();
      expect(find.text('Panel content'), findsOneWidget);
      expect(tester.getSize(find.byType(GazePanel)).width, 240);
      update(() => open = false);
      await tester.pumpAndSettle();
      expect(find.text('Panel content'), findsNothing);
      expect(tester.getSize(find.byType(GazePanel)).width, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion changes pages immediately without a lingering animation',
    (tester) async {
      var index = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return GazePageStack(
                  index: index,
                  children: const [Text('First'), Text('Second')],
                );
              },
            ),
          ),
        ),
      );
      update(() => index = 1);
      await tester.pump();
      await tester.pump();
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
