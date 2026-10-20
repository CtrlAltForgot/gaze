import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/lyrics_view.dart';
import 'package:gaze/desktop/media_mode.dart';
import 'package:gaze/desktop/playlists_page.dart';
import 'package:gaze/desktop/queue_panel.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/main.dart';
import '../widget_test.dart' as fixtures;
import 'playlist_management_test.dart' show ManagedApi, song;

void main() {
  for (final width in [800.0, 1280.0, 1800.0]) {
    testWidgets(
      'center lyrics and queue are independent and retain the playlist at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.reset);
        final api = ManagedApi()
          ..songs['mix'] = List.generate(60, (i) => song('entry-$i'));
        final connection = JellyfinConnectionController(
          credentialStore: fixtures.FakeCredentialStore(),
          apiFactory: (_) => api,
        );
        final playback = fixtures.FakePlaybackController();
        await connection.connect(
          serverAddress: 'https://music.example',
          userName: 'listener',
          password: 'test',
        );
        await tester.pumpWidget(
          GazeApp(
            playbackController: playback,
            connectionController: connection,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          width < 920
              ? find.bySemanticsLabel('Playlists')
              : find.text('Playlists'),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(PlaylistsPage),
            matching: find.text('Evening mix'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Play playlist'));
        await tester.pumpAndSettle();
        final browser = find.descendant(
          of: find.byType(PlaylistsPage),
          matching: find.byType(CustomScrollView),
        );
        await tester.drag(browser, const Offset(0, -430));
        await tester.pumpAndSettle();
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: browser, matching: find.byType(Scrollable)).first,
        );
        final offset = scroll.position.pixels;
        expect(offset, greaterThan(100));

        // Start with the queue open, then bring lyrics into the center.
        await tester.tap(find.byTooltip('Show queue'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Show lyrics'));
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsOneWidget);
        expect(find.byType(LyricsView), findsOneWidget);
        expect(find.text('Up next · 59'), findsOneWidget);
        expect(find.byType(PlaylistsPage), findsNothing);
        final lyricsRect = tester.getRect(find.byType(LyricsView));
        final queueRect = tester.getRect(find.byType(QueuePanel));
        expect(lyricsRect.right, lessThanOrEqualTo(queueRect.left));
        expect(lyricsRect.width, greaterThan(300));
        expect(lyricsRect.left, greaterThan(70));
        await tester.tap(find.text('Remembered line'));
        await tester.pumpAndSettle();
        expect(playback.soughtPosition, const Duration(seconds: 12));

        tester
            .widget<MediaModeArtwork>(find.byType(MediaModeArtwork))
            .onExpand!();
        await tester.pumpAndSettle();
        expect(
          tester.widget<LyricsView>(find.byType(LyricsView)).immersive,
          isTrue,
        );
        expect(find.byType(QueuePanel), findsNothing);
        await tester.tap(find.byTooltip('Back to library'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<LyricsView>(find.byType(LyricsView)).immersive,
          isFalse,
        );
        expect(find.byType(QueuePanel), findsOneWidget);

        await tester.tap(find.byTooltip('Close queue'));
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsNothing);
        expect(find.byType(LyricsView), findsOneWidget);
        await tester.tap(find.byTooltip('Show queue'));
        await tester.pumpAndSettle();
        expect(find.byType(LyricsView), findsOneWidget);
        await tester.tap(find.byTooltip('Close lyrics'));
        await tester.pumpAndSettle();
        expect(find.byType(LyricsView), findsNothing);
        expect(find.byType(QueuePanel), findsOneWidget);
        expect(scroll.mounted, isTrue);
        expect(scroll.position.pixels, closeTo(offset, 1));
        await tester.tap(find.byTooltip('Close queue'));
        await tester.pumpAndSettle();
        expect(find.byType(PlaylistsPage), findsOneWidget);

        await tester.tap(find.byTooltip('Show lyrics'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(LyricsView), findsNothing);
        expect(scroll.position.pixels, closeTo(offset, 1));
        await tester.tap(find.byTooltip('Show lyrics'));
        await tester.pumpAndSettle();
        await tester.tap(
          width < 920 ? find.bySemanticsLabel('Home') : find.text('Home'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LyricsView), findsNothing);
        expect(find.text('Your music, brought forward.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  }
}
