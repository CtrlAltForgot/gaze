import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gaze/lyrics/lrclib_lyrics_provider.dart';
import 'package:gaze/storage/local_content_cache.dart';

void main() {
  test('timed lyrics handle repeated timestamps, offsets, and plain lines', () {
    final lines = parseLrc(
      '[offset:-100]\n[00:02.25][00:04.005]A line\n[00:05]Next',
    );
    expect(lines.map((line) => line.start!.inMilliseconds), [2150, 3905, 4900]);
    expect(lines.first.text, 'A line');
  });
  test(
    'lyrics use public metadata, retry a primary artist, and reuse cache',
    () async {
      final cache = SqliteLocalContentCache.inMemory();
      addTearDown(cache.dispose);
      final requests = <http.Request>[];
      final provider = LrclibLyricsProvider(
        MockClient((request) async {
          requests.add(request);
          expect(request.url.host, 'lrclib.net');
          expect(request.headers.keys, isNot(contains('Authorization')));
          if (request.url.queryParameters['artist_name'] == 'Singer; Guest')
            return http.Response('{}', 404);
          return http.Response(
            jsonEncode({'syncedLyrics': '[00:01.00]Test line'}),
            200,
          );
        }),
        cache: cache,
      );
      final first = await provider.find(
        title: 'Test song',
        artist: 'Singer; Guest',
        duration: const Duration(seconds: 180),
      );
      expect(first!.isSynchronized, isTrue);
      expect(first.source, 'LRCLIB');
      final again = await provider.find(
        title: 'Test song',
        artist: 'Singer; Guest',
        duration: const Duration(seconds: 180),
      );
      expect(again!.lines.first.text, 'Test line');
      expect(requests.length, 2);
    },
  );
  test('a failed provider response is retryable, a miss is cached', () async {
    final cache = SqliteLocalContentCache.inMemory();
    addTearDown(cache.dispose);
    var requests = 0;
    final provider = LrclibLyricsProvider(
      MockClient((_) async => http.Response('{}', ++requests == 1 ? 503 : 404)),
      cache: cache,
    );
    Future<void> find() async {
      await provider.find(
        title: 'Song',
        artist: 'Artist',
        duration: Duration.zero,
      );
    }

    await expectLater(find(), throwsStateError);
    await find();
    await find();
    expect(requests, 2);
  });
  test(
    'prefers matching timed search results over plain text and rejects other recordings',
    () async {
      final cache = SqliteLocalContentCache.inMemory();
      addTearDown(cache.dispose);
      final provider = LrclibLyricsProvider(
        MockClient((request) async {
          if (request.url.path == '/api/get')
            return http.Response(
              jsonEncode({'plainLyrics': 'Plain words'}),
              200,
            );
          expect(request.url.path, '/api/search');
          return http.Response(
            jsonEncode([
              {
                'trackName': 'Song',
                'artistName': 'Other artist',
                'duration': 180,
                'syncedLyrics': '[00:01]Wrong artist',
              },
              {
                'trackName': 'Song (Live)',
                'artistName': 'Artist',
                'duration': 180,
                'syncedLyrics': '[00:01]Wrong version',
              },
              {
                'trackName': 'Song',
                'artistName': 'Artist',
                'duration': 210,
                'syncedLyrics': '[00:01]Wrong length',
              },
              {
                'trackName': 'Song',
                'artistName': 'Artist',
                'duration': 181,
                'syncedLyrics': '[00:12.250]Matching words',
              },
            ]),
            200,
          );
        }),
        cache: cache,
      );
      final lyrics = await provider.find(
        title: 'Song',
        artist: 'Artist',
        duration: const Duration(seconds: 180),
      );
      expect(lyrics!.hasTiming, isTrue);
      expect(lyrics.lines.single.text, 'Matching words');
      expect(lyrics.lines.single.start, const Duration(milliseconds: 12250));
    },
  );
  test(
    'preserves comma-containing artist names and keeps plain words if search fails',
    () async {
      final cache = SqliteLocalContentCache.inMemory();
      addTearDown(cache.dispose);
      var requests = 0;
      final provider = LrclibLyricsProvider(
        MockClient((request) async {
          requests++;
          expect(
            request.url.queryParameters['artist_name'],
            'Earth, Wind & Fire',
          );
          return request.url.path == '/api/get'
              ? http.Response(
                  jsonEncode({'plainLyrics': 'Available words'}),
                  200,
                )
              : http.Response('{}', 503);
        }),
        cache: cache,
      );
      final lyrics = await provider.find(
        title: 'Song',
        artist: 'Earth, Wind & Fire',
        duration: const Duration(seconds: 180),
      );
      expect(lyrics!.hasTiming, isFalse);
      expect(lyrics.lines.single.text, 'Available words');
      expect(requests, 2);
    },
  );
}
