import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import 'playback_queue_controller_test.dart' show QueueTestPlaybackController;

RemotePlaybackSource song(String title) => RemotePlaybackSource(
  uri: Uri.parse('https://music.example/$title'),
  title: title,
  artist: 'Artist',
  itemId: title,
);

void main() {
  late QueueTestPlaybackController playback;
  late PlaybackQueueController queue;
  setUp(() {
    playback = QueueTestPlaybackController();
    queue = PlaybackQueueController(
      playbackController: playback,
      random: Random(42),
    );
  });
  tearDown(() async {
    await queue.dispose();
    await playback.dispose();
  });
  Future<void> complete() async {
    playback.emitCompleted();
    playback
        .emitCompleted(); // Duplicate engine notifications must not skip twice.
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'shuffle preserves current source, history and duplicate slots; off restores order',
    () async {
      final duplicate = song('B');
      final songs = [
        song('A'),
        duplicate,
        song('C'),
        duplicate,
        song('D'),
        song('E'),
      ];
      await queue.playAlbum(songs, startIndex: 1);
      playback.emitPosition(const Duration(seconds: 18));
      queue.setShuffle(true);
      expect(queue.state.items.take(2), songs.take(2));
      expect(queue.state.items, unorderedEquals(songs));
      expect(queue.state.items, isNot(orderedEquals(songs)));
      expect(playback.loadedTitles, ['B']);
      expect(playback.state.position, const Duration(seconds: 18));
      queue.setShuffle(false);
      expect(queue.state.items, orderedEquals(songs));
    },
  );

  test(
    'new albums honor modes and include earlier songs after selected track',
    () async {
      queue.setShuffle(true);
      queue.setRepeatMode(PlaybackRepeatMode.all);
      final songs = [song('A'), song('B'), song('C'), song('D')];
      await queue.playAlbum(songs, startIndex: 2);
      expect(queue.state.currentIndex, 0);
      expect(queue.state.items.first, same(songs[2]));
      expect(queue.state.items, unorderedEquals(songs));
      expect(queue.state.repeatMode, PlaybackRepeatMode.all);
    },
  );

  test(
    'repeat off stops at end; repeat all wraps; repeat one only affects completion',
    () async {
      await queue.playAlbum([song('A'), song('B')], startIndex: 1);
      await complete();
      expect(playback.loadedTitles, ['B']);
      queue.setRepeatMode(PlaybackRepeatMode.all);
      // The next actual playing state resets completion tracking.
      await queue.playAt(1);
      await Future<void>.delayed(Duration.zero);
      await complete();
      expect(playback.loadedTitles, ['B', 'B', 'A']);
      queue.setRepeatMode(PlaybackRepeatMode.one);
      await complete();
      expect(playback.loadedTitles, ['B', 'B', 'A', 'A']);
      await queue.next();
      expect(playback.loadedTitles.last, 'B');
      expect(queue.state.repeatMode, PlaybackRepeatMode.one);
    },
  );

  test(
    'one-track repeat and previous wrap preserve paused navigation',
    () async {
      await queue.playAlbum([song('A')], startIndex: 0);
      queue.setRepeatMode(PlaybackRepeatMode.all);
      final plays = playback.playCalls;
      await queue.next(play: false);
      await queue.previous(play: false);
      expect(playback.playCalls, plays);
      expect(queue.state.hasNext, isTrue);
      await complete();
      expect(playback.playCalls, plays + 1);
    },
  );

  test(
    'shuffled passes visit each slot once and do not immediately repeat at wrap',
    () async {
      queue.setShuffle(true);
      queue.setRepeatMode(PlaybackRepeatMode.all);
      await queue.playAlbum([
        song('A'),
        song('B'),
        song('C'),
        song('D'),
      ], startIndex: 0);
      for (var i = 0; i < 3; i++) {
        await queue.next();
      }
      final last = playback.loadedTitles.last;
      await queue.next();
      expect(playback.loadedTitles.last, isNot(last));
      for (var i = 0; i < 3; i++) {
        await queue.next();
      }
      expect(
        playback.loadedTitles.take(4),
        unorderedEquals(['A', 'B', 'C', 'D']),
      );
      expect(
        playback.loadedTitles.skip(4),
        unorderedEquals(['A', 'B', 'C', 'D']),
      );
    },
  );

  test(
    'queue edits retain every distinct slot and play-next intent while shuffled',
    () async {
      await queue.playAlbum([
        song('A'),
        song('B'),
        song('C'),
        song('D'),
      ], startIndex: 0);
      queue.setShuffle(true);
      await queue.enqueue([song('Next')], next: true);
      await queue.enqueue([song('End')]);
      expect(queue.state.items[1].title, 'Next');
      queue.removeAt(3);
      queue.moveUpcoming(queue.state.items.length - 1, 2);
      final remaining = queue.state.items.toList();
      queue.setShuffle(false);
      expect(queue.state.items, unorderedEquals(remaining));
      expect(queue.state.items[1].title, 'Next');
      expect(playback.loadedTitles, ['A']);
      queue.setRepeatMode(PlaybackRepeatMode.all);
      queue.clearUpcoming();
      expect(queue.state.items.map((s) => s.title), ['A']);
      queue.clearUpcoming();
      expect(queue.state.items.length, 1);
    },
  );

  test(
    'restored shuffle preserves order and can recover original upcoming order',
    () async {
      final songs = [song('A'), song('D'), song('B'), song('C')];
      await queue.restore(
        songs,
        currentIndex: 0,
        volume: .4,
        shuffleEnabled: true,
        repeatMode: PlaybackRepeatMode.one,
        originalOrder: [0, 2, 3, 1],
      );
      expect(playback.playCalls, 0);
      expect(queue.state.items, songs);
      expect(queue.state.repeatMode, PlaybackRepeatMode.one);
      queue.setShuffle(false);
      expect(queue.state.items.map((s) => s.title), ['A', 'B', 'C', 'D']);
    },
  );

  test('invalid saved order and empty queues remain safe', () async {
    queue.setRepeatMode(PlaybackRepeatMode.all);
    queue.setShuffle(true);
    await queue.next();
    await queue.previous();
    expect(queue.state.hasNext, isFalse);
    await queue.restore(
      [song('A'), song('B')],
      currentIndex: 0,
      volume: 1,
      shuffleEnabled: true,
      originalOrder: [1, 1],
    );
    queue.setShuffle(false);
    expect(queue.state.items.map((s) => s.title), ['A', 'B']);
  });
}
