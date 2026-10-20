import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/track_lyrics.dart';
import 'package:gaze/lyrics/lyrics_provider.dart';
import '../widget_test.dart' as fixtures;

const plain = TrackLyrics(
  lines: [LyricLine(text: 'Library words')],
  isSynchronized: false,
);
const timed = TrackLyrics(
  lines: [LyricLine(text: 'Timed words', start: Duration(seconds: 12))],
  isSynchronized: true,
);

class LyricsApi extends fixtures.FakeJellyfinApi {
  TrackLyrics? result = plain;
  @override
  Future<TrackLyrics?> getLyrics({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String trackId,
  }) async => result;
}

class Provider implements LyricsProvider {
  TrackLyrics? result = timed;
  bool fail = false;
  int calls = 0;
  @override
  Future<TrackLyrics?> find({
    required String title,
    required String artist,
    required Duration duration,
  }) async {
    calls++;
    if (fail) throw StateError('offline');
    return result;
  }
}

void main() {
  test(
    'timed library first, upgrades plain library, keeps plain on provider failure',
    () async {
      final api = LyricsApi();
      final provider = Provider();
      final connection = JellyfinConnectionController(
        credentialStore: fixtures.FakeCredentialStore(),
        apiFactory: (_) => api,
        lyricsProvider: provider,
      );
      addTearDown(connection.dispose);
      await connection.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      Future<TrackLyrics?> load() => connection.loadLyrics(
        'song',
        title: 'Song',
        artist: 'Artist',
        duration: const Duration(seconds: 180),
      );
      expect(await load(), same(timed));
      expect(provider.calls, 1);
      api.result = timed;
      expect(await load(), same(timed));
      expect(provider.calls, 1);
      api.result = plain;
      provider.fail = true;
      expect(await load(), same(plain));
      provider.fail = false;
      provider.result = null;
      expect(await load(), same(plain));
    },
  );
  test(
    'timeline handles untimed headers, gaps, repeated stamps and backward seeks',
    () {
      const lyrics = TrackLyrics(
        isSynchronized: true,
        lines: [
          LyricLine(text: 'Header'),
          LyricLine(text: 'First', start: Duration(seconds: 3)),
          LyricLine(text: 'Untimed'),
          LyricLine(text: '', start: Duration(seconds: 6)),
          LyricLine(text: 'Last', start: Duration(seconds: 10)),
        ],
      );
      expect(lyrics.lineAt(Duration.zero), -1);
      expect(lyrics.lineAt(const Duration(seconds: 4)), 1);
      expect(lyrics.lineAt(const Duration(seconds: 7)), 3);
      expect(lyrics.lineAt(const Duration(seconds: 40)), 4);
      expect(lyrics.lineAt(const Duration(seconds: 3)), 1);
      expect(lyrics.lineAt(const Duration(microseconds: 2999977)), 1);
      expect(plain.lineAt(const Duration(seconds: 40)), -1);
    },
  );
}
