import 'dart:ui' show Tristate;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/design/gaze_theme.dart';
import 'package:gaze/desktop/desktop_shell.dart';
import 'package:gaze/desktop/lyrics_view.dart';
import 'package:gaze/desktop/media_mode.dart';
import '../party/party_lyrics_test.dart' show GuestLyricsFixture;

void main() {
  testWidgets(
    'signed-out guests open lyrics, seek together, and follow songs in both views',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final f = GuestLyricsFixture();
      addTearDown(f.dispose);
      // Identical titles/artists must still reload when the shared track ID changes.
      (f.api.data['queue'] as List)[1]['title'] = 'Shared song';
      await f.join();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildGazeTheme(),
          home: DesktopShell(
            connectionController: f.connection,
            playbackController: f.guarded,
            queueController: f.queue,
            partyController: f.party,
            onOpenJellyfinConnection: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.connection.state.isConnected, false);
      expect(f.player.state.itemId, isNull);
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('Shared first line'), findsOneWidget);
      await tester.tap(find.text('Shared second line'));
      await tester.pumpAndSettle();
      expect(
        f.api.bodies.whereType<Map>().any(
          (b) => b['action'] == 'seek' && b['positionMs'] == 12000,
        ),
        true,
      );
      expect(f.player.state.position, const Duration(seconds: 12));
      expect(
        tester
            .getSemantics(
              find.ancestor(
                of: find.text('Shared second line'),
                matching: find.byType(InkWell),
              ),
            )
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      f.api.data = {...f.api.data, 'index': 1, 'positionMs': 0};
      await f.party.poll();
      await tester.pumpAndSettle();
      expect(find.text('Shared first line'), findsNothing);
      expect(find.text('Next first line'), findsOneWidget);
      tester
          .widget<MediaModeArtwork>(find.byType(MediaModeArtwork))
          .onExpand!();
      await tester.pumpAndSettle();
      expect(
        tester.widget<LyricsView>(find.byType(LyricsView)).immersive,
        true,
      );
      expect(find.text('Next first line'), findsOneWidget);
      await f.party.leave();
      await tester.pumpAndSettle();
      expect(find.text('Next first line'), findsNothing);
      expect(f.library.lyricCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
