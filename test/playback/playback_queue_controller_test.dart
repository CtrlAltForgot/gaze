import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';

void main() {
  test(
    'plays an album from the selected track and supports navigation',
    () async {
      final playback = QueueTestPlaybackController();
      final queue = PlaybackQueueController(playbackController: playback);
      final tracks = [_source('One'), _source('Two'), _source('Three')];

      await queue.playAlbum(tracks, startIndex: 1);
      expect(playback.loadedTitles, ['Two']);
      expect(queue.state.hasPrevious, isTrue);
      expect(queue.state.hasNext, isTrue);

      await queue.next();
      expect(playback.loadedTitles, ['Two', 'Three']);
      expect(queue.state.hasNext, isFalse);

      await queue.previous();
      expect(playback.loadedTitles, ['Two', 'Three', 'Two']);

      await queue.dispose();
      await playback.dispose();
    },
  );

  test('advances once when playback completes', () async {
    final playback = QueueTestPlaybackController();
    final queue = PlaybackQueueController(playbackController: playback);
    await queue.playAlbum([_source('One'), _source('Two')], startIndex: 0);

    playback.emitCompleted();
    await Future<void>.delayed(Duration.zero);

    expect(playback.loadedTitles, ['One', 'Two']);
    expect(queue.state.currentIndex, 1);
    await queue.dispose();
    await playback.dispose();
  });
}

RemotePlaybackSource _source(String title) => RemotePlaybackSource(
  uri: Uri.parse('https://music.example/$title'),
  title: title,
  artist: 'Artist',
);

class QueueTestPlaybackController implements PlaybackController {
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<String> loadedTitles = [];
  PlaybackSnapshot _state = const PlaybackSnapshot();

  void emitCompleted() {
    _state = _state.copyWith(status: PlaybackStatus.completed, completed: true);
    _states.add(_state);
  }

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) async {
    loadedTitles.add(source.title);
    _state = PlaybackSnapshot(
      status: PlaybackStatus.ready,
      title: source.title,
      artist: source.artist,
    );
    _states.add(_state);
  }

  @override
  Future<void> loadLocalFile(String path) async {}

  @override
  Future<void> loadRemoteUrl(Uri url) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _states.close();
}
