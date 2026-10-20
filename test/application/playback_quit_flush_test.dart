import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/application/playback_state_coordinator.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import 'package:gaze/storage/sqlite_playback_state_store.dart';

import '../desktop/linux_media_session_test.dart' show MediaKeyTestPlayback;
import '../widget_test.dart' as fixtures;

void main() {
  test(
    'explicit Quit flush saves the latest position between periodic writes',
    () async {
      final connection = fixtures.createFakeConnectionController();
      await connection.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test-password',
      );
      final playback = MediaKeyTestPlayback();
      final queue = PlaybackQueueController(playbackController: playback);
      final store = SqlitePlaybackStateStore.inMemory();
      final coordinator = PlaybackStateCoordinator(
        playbackController: playback,
        queueController: queue,
        connectionController: connection,
        store: store,
      );
      await Future<void>.delayed(Duration.zero);
      await queue.playAlbum([
        RemotePlaybackSource(
          uri: Uri.parse('https://music.example/song'),
          title: 'Song',
          artist: 'Artist',
          itemId: 'song',
        ),
      ], startIndex: 0);
      await coordinator.flush();
      expect((await store.read())!.position, Duration.zero);
      await playback.seek(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      expect((await store.read())!.position, Duration.zero);
      await coordinator.flush();
      final saved = (await store.read())!;
      expect(saved.position, const Duration(seconds: 3));
      expect(saved.items.single.itemId, 'song');
      expect(playback.state.status, PlaybackStatus.playing);
      expect(playback.commands, isNot(contains('stop')));
      await coordinator.dispose();
      await queue.dispose();
      await playback.dispose();
      await connection.dispose();
    },
  );
}
