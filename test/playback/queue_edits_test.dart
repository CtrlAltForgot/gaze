import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import '../widget_test.dart' as fixtures;

RemotePlaybackSource source(String title) => RemotePlaybackSource(
  uri: Uri.parse('https://music.example/$title'),
  title: title,
  artist: 'Artist',
  itemId: title,
);
void main() {
  test(
    'adding and reordering upcoming songs preserves the current source',
    () async {
      final playback = fixtures.FakePlaybackController();
      final queue = PlaybackQueueController(playbackController: playback);
      addTearDown(queue.dispose);
      addTearDown(playback.dispose);
      await queue.playAlbum([
        source('One'),
        source('Two'),
        source('Three'),
      ], startIndex: 0);
      final current = playback.loadedRemoteSource;
      await queue.enqueue([source('Next')], next: true);
      expect(queue.state.items.map((s) => s.title), [
        'One',
        'Next',
        'Two',
        'Three',
      ]);
      queue.moveUpcoming(3, 1);
      expect(queue.state.items.map((s) => s.title), [
        'One',
        'Three',
        'Next',
        'Two',
      ]);
      queue.removeAt(2);
      expect(queue.state.items.map((s) => s.title), ['One', 'Three', 'Two']);
      expect(playback.loadedRemoteSource, same(current));
      queue.removeAt(0);
      queue.moveUpcoming(0, 2);
      expect(queue.state.currentIndex, 0);
      expect(queue.state.items.first.title, 'One');
      queue.clearUpcoming();
      expect(queue.state.items.map((s) => s.title), ['One']);
      expect(playback.loadedRemoteSource, same(current));
    },
  );
  test(
    'removing history preserves current selection and skipping uses the edited order',
    () async {
      final playback = fixtures.FakePlaybackController();
      final queue = PlaybackQueueController(playbackController: playback);
      addTearDown(queue.dispose);
      addTearDown(playback.dispose);
      await queue.playAlbum([
        source('One'),
        source('Two'),
        source('Three'),
      ], startIndex: 1);
      queue.removeAt(0);
      expect(queue.state.currentIndex, 0);
      expect(playback.loadedRemoteSource!.title, 'Two');
      await queue.enqueue([source('Next')], next: true);
      await queue.next();
      expect(playback.loadedRemoteSource!.title, 'Next');
      await queue.playAt(2);
      expect(playback.loadedRemoteSource!.title, 'Three');
    },
  );
  test(
    'adding to an empty queue prepares a track without starting playback',
    () async {
      final playback = fixtures.FakePlaybackController();
      final queue = PlaybackQueueController(playbackController: playback);
      addTearDown(queue.dispose);
      addTearDown(playback.dispose);
      await queue.enqueue([source('One')]);
      expect(queue.state.currentIndex, 0);
      expect(playback.state.status, PlaybackStatus.ready);
      expect(playback.loadedRemoteSource!.title, 'One');
    },
  );
}
