import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/main.dart';
import 'package:gaze/desktop/playback_controls.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import '../widget_test.dart' as fixtures;

void main() {
  testWidgets(
    'keyboard transport skips unavailable actions and activates play',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var shuffle = false;
      var playing = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => PlaybackControls(
                playing: playing,
                shuffleEnabled: shuffle,
                repeatMode: PlaybackRepeatMode.off,
                onShuffle: () => setState(() => shuffle = !shuffle),
                onPrevious: null,
                onPlayPause: () => setState(() => playing = !playing),
                onNext: null,
                onRepeat: () {},
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(shuffle, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playing, isTrue);
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playing, isFalse);
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
      semantics.dispose();
    },
  );

  for (final width in [800.0, 1100.0, 1600.0]) {
    testWidgets('shuffle and repeat controls cycle clearly at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        GazeApp(
          playbackController: fixtures.FakePlaybackController(),
          connectionController: fixtures.createFakeConnectionController(),
        ),
      );
      await tester.pump();
      expect(find.bySemanticsLabel('Shuffle off'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Shuffle off'));
      await tester.pump();
      expect(find.bySemanticsLabel('Shuffle on'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Repeat off'));
      await tester.pump();
      expect(find.bySemanticsLabel('Repeat queue'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      await tester.tap(find.bySemanticsLabel('Repeat queue'));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(PlaybackControls),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Repeat one'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Repeat one'));
      await tester.tap(find.bySemanticsLabel('Shuffle on'));
      await tester.pump();
      expect(find.bySemanticsLabel('Repeat off'), findsOneWidget);
      expect(find.bySemanticsLabel('Shuffle off'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(
        find.descendant(
          of: find.byType(PlaybackControls),
          matching: find.byType(Tooltip),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
