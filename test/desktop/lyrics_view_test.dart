import 'dart:async';
import 'dart:ui' show Tristate;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/lyrics_view.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/track_lyrics.dart';
import 'package:gaze/playback/playback_controller.dart';
import '../widget_test.dart' as fixtures;

class Connection extends JellyfinConnectionController {
  Connection()
    : super(
        credentialStore: fixtures.FakeCredentialStore(),
        apiFactory: (_) => fixtures.FakeJellyfinApi(),
      );
  final requests = <Duration>[];
  Completer<TrackLyrics?>? pending;
  TrackLyrics result = TrackLyrics(
    isSynchronized: true,
    lines: List.generate(
      16,
      (i) => LyricLine(
        text: i == 3
            ? 'A long line that wraps naturally across several lines without ever hiding the last words of the lyric'
            : 'Line $i',
        start: Duration(seconds: i * 10),
      ),
    ),
  );
  @override
  Future<TrackLyrics?> loadLyrics(
    String id, {
    String? title,
    String? artist,
    Duration duration = Duration.zero,
  }) async {
    requests.add(duration);
    return pending?.future ?? result;
  }
}

class Playback extends fixtures.FakePlaybackController {
  final changes = StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot value = const PlaybackSnapshot(
    itemId: 'song',
    title: 'Song',
    artist: 'Artist',
  );
  @override
  PlaybackSnapshot get state => value;
  @override
  Stream<PlaybackSnapshot> get states => changes.stream;
  void emit(PlaybackSnapshot v) {
    value = v;
    changes.add(v);
  }

  @override
  Future<void> seek(Duration position) async {
    await super.seek(position);
    emit(value.copyWith(position: position));
  }

  @override
  Future<void> dispose() async {
    await changes.close();
    await super.dispose();
  }
}

void main() {
  testWidgets(
    'unboxed lyrics follow playback, wrap and seek from a line while paused',
    (tester) async {
      final connection = Connection();
      final playback = Playback();
      addTearDown(connection.dispose);
      addTearDown(playback.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 600,
                child: LyricsView(
                  connectionController: connection,
                  playbackController: playback,
                  onClose: () {},
                  immersive: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lyrics'), findsNothing);
      expect(find.byTooltip('Close lyrics'), findsNothing);
      final view = find.byType(LyricsView);
      expect(
        find.descendant(of: view, matching: find.byType(Divider)),
        findsNothing,
      );
      expect(
        find.descendant(of: view, matching: find.byType(ColoredBox)),
        findsNothing,
      );
      playback.emit(
        playback.state.copyWith(position: const Duration(seconds: 30)),
      );
      await tester.pumpAndSettle();
      final longLine = find.textContaining('A long line that wraps');
      expect(tester.widget<Text>(longLine).maxLines, isNull);
      expect(tester.getSize(longLine).height, greaterThan(90));
      expect(
        tester
            .getSemantics(
              find.ancestor(of: longLine, matching: find.byType(InkWell)),
            )
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await tester.tap(find.text('Line 4'));
      await tester.pumpAndSettle();
      expect(playback.soughtPosition, const Duration(seconds: 40));
      expect(playback.state.status, PlaybackStatus.idle);
      playback.emit(
        playback.state.copyWith(position: const Duration(seconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(
        (tester.getCenter(find.text('Line 1')).dy - tester.getCenter(view).dy)
            .abs(),
        lessThan(3),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'reloads once duration arrives and rejects an obsolete lyric response',
    (tester) async {
      final connection = Connection();
      final playback = Playback();
      addTearDown(connection.dispose);
      addTearDown(playback.dispose);
      final stale = Completer<TrackLyrics?>();
      connection.pending = stale;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricsView(
              connectionController: connection,
              playbackController: playback,
              onClose: () {},
            ),
          ),
        ),
      );
      connection.pending = null;
      playback.emit(
        playback.state.copyWith(duration: const Duration(seconds: 180)),
      );
      await tester.pumpAndSettle();
      stale.complete(
        const TrackLyrics(
          lines: [LyricLine(text: 'Obsolete')],
          isSynchronized: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(connection.requests, [
        Duration.zero,
        const Duration(seconds: 180),
      ]);
      expect(find.text('Obsolete'), findsNothing);
      expect(find.text('Line 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'retained hidden lyrics defer new song lookups until they are reopened',
    (tester) async {
      final connection = Connection();
      final playback = Playback();
      final active = ValueNotifier(true);
      addTearDown(connection.dispose);
      addTearDown(playback.dispose);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (context, value, child) =>
                  TickerMode(enabled: value, child: child!),
              child: LyricsView(
                connectionController: connection,
                playbackController: playback,
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(connection.requests.length, 1);
      active.value = false;
      await tester.pumpAndSettle();
      playback.emit(
        playback.state.copyWith(itemId: 'next-song', title: 'Next song'),
      );
      await tester.pumpAndSettle();
      expect(connection.requests.length, 1);
      active.value = true;
      await tester.pumpAndSettle();
      expect(connection.requests.length, 2);
      expect(find.text('Next song'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
