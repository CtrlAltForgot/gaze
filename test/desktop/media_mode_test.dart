import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/main.dart';
import 'package:gaze/desktop/media_mode.dart';
import 'package:gaze/playback/playback_controller.dart';
import '../widget_test.dart' as fixtures;

void main() {
  for (final width in [800.0, 1280.0, 1800.0]) {
    testWidgets(
      'Media Mode opens and returns without losing playback at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final playback = fixtures.FakePlaybackController();
        await playback.loadRemoteSource(
          RemotePlaybackSource(
            uri: Uri.parse('https://audio.example/song'),
            title: 'Test song',
            artist: 'Test artist',
          ),
        );
        await tester.pumpWidget(
          GazeApp(
            playbackController: playback,
            connectionController: fixtures.createFakeConnectionController(),
          ),
        );
        await tester.pump();
        final art = find.byType(MediaModeArtwork);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer();
        await mouse.moveTo(tester.getCenter(art));
        await tester.pump();
        await tester.tap(find.byTooltip('Open Media Mode'));
        await tester.pumpAndSettle();
        expect(find.text('MEDIA MODE'), findsOneWidget);
        expect(find.text('Background motion: On'), findsOneWidget);
        await tester.tap(find.text('Background motion: On'));
        await tester.pumpAndSettle();
        expect(find.text('Background motion: Off'), findsOneWidget);
        await tester.tap(find.text('Background motion: Off'));
        await tester.pumpAndSettle();
        expect(playback.state.title, 'Test song');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('MEDIA MODE'), findsNothing);
        expect(find.text('Your music, brought forward.'), findsOneWidget);
        // The retained page must regain Escape focus on every reopening.
        await tester.tap(find.byTooltip('Open Media Mode'));
        await tester.pumpAndSettle();
        expect(find.text('MEDIA MODE'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('MEDIA MODE'), findsNothing);
        expect(tester.takeException(), isNull);
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  }
}
