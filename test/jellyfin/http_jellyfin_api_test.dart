import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/http_jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/library/album_summary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('JellyfinServerAddress', () {
    test('accepts and normalizes HTTP and HTTPS addresses', () {
      final httpAddress = JellyfinServerAddress.parse(
        'http://music.local:8096/',
      );
      final httpsAddress = JellyfinServerAddress.parse(
        'https://music.example/jellyfin/',
      );

      expect(httpAddress.isEncrypted, isFalse);
      expect(httpAddress.toString(), 'http://music.local:8096');
      expect(
        httpsAddress.endpoint('/System/Info/Public').toString(),
        'https://music.example/jellyfin/System/Info/Public',
      );
    });

    test('rejects unsafe or unsupported address forms', () {
      for (final value in [
        'music.local:8096',
        'ftp://music.local',
        'http://user:password@music.local',
        'http://music.local?token=secret',
      ]) {
        expect(
          () => JellyfinServerAddress.parse(value),
          throwsA(isA<JellyfinConnectionException>()),
        );
      }
    });
  });

  group('HttpJellyfinApi', () {
    test('creates a direct-play source with header authentication', () {
      final api = _createApi(MockClient((_) async => http.Response('', 200)));

      final source = api.createDirectPlaySource(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        itemId: 'track-id',
      );

      expect(
        source.uri.toString(),
        'https://music.example/Audio/track-id/stream?static=true',
      );
      expect(source.uri.toString(), isNot(contains('private-access-token')));
      expect(source.headers['Authorization'], contains('private-access-token'));
      api.close();
    });

    test('reports playback progress without exposing the token', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://music.example/Sessions/Playing/Progress',
        );
        expect(request.url.toString(), isNot(contains('private-access-token')));
        expect(
          request.headers['authorization'],
          contains('private-access-token'),
        );
        expect(jsonDecode(request.body), containsPair('ItemId', 'track-id'));
        expect(
          jsonDecode(request.body),
          containsPair('PositionTicks', 120000000),
        );
        expect(jsonDecode(request.body), containsPair('IsPaused', true));
        return http.Response('', 204);
      });
      final api = _createApi(client);

      await api.reportPlayback(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        event: JellyfinPlaybackEvent.progress,
        itemId: 'track-id',
        position: const Duration(seconds: 12),
        volume: 0.75,
        paused: true,
      );

      api.close();
    });

    test('reads public Jellyfin server information over HTTP', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'http://music.local:8096/System/Info/Public',
        );
        return http.Response(
          jsonEncode({
            'Id': 'server-id',
            'ServerName': 'Music Server',
            'Version': '10.11.0',
          }),
          200,
        );
      });
      final api = _createApi(client);

      final info = await api.getPublicServerInfo(
        JellyfinServerAddress.parse('http://music.local:8096'),
      );

      expect(info.id, 'server-id');
      expect(info.name, 'Music Server');
      expect(info.version, '10.11.0');
      api.close();
    });

    test('authenticates without putting credentials in the URL', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://music.example/Users/AuthenticateByName',
        );
        expect(request.url.userInfo, isEmpty);
        expect(
          request.headers['authorization'],
          'MediaBrowser Client="gaze", Device="test desktop", '
          'DeviceId="test-device-id", Version="0.1.0"',
        );
        expect(jsonDecode(request.body), {
          'Username': 'listener',
          'Pw': 'private-password',
        });
        return http.Response(
          jsonEncode({
            'AccessToken': 'private-access-token',
            'User': {'Id': 'user-id', 'Name': 'listener'},
          }),
          200,
        );
      });
      final api = _createApi(client);

      final session = await api.authenticate(
        address: JellyfinServerAddress.parse('https://music.example'),
        userName: 'listener',
        password: 'private-password',
      );

      expect(session.accessToken, 'private-access-token');
      expect(session.userId, 'user-id');
      expect(session.userName, 'listener');
      api.close();
    });

    test(
      'loads album metadata before requesting authenticated artwork',
      () async {
        final client = MockClient((request) async {
          expect(request.url.query, isNot(contains('private-access-token')));
          expect(
            request.headers['authorization'],
            contains('Token="private-access-token"'),
          );
          if (request.url.path.endsWith('/Items/album-id/Images/Primary')) {
            return http.Response.bytes([1, 2, 3], 200);
          }
          expect(request.url.path, '/Users/user-id/Items');
          expect(request.url.queryParameters['IncludeItemTypes'], 'MusicAlbum');
          expect(request.url.queryParameters['SortBy'], 'DateCreated');
          return http.Response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'album-id',
                  'Name': 'Real Album',
                  'AlbumArtist': 'Real Artist',
                  'ImageTags': {'Primary': 'image-tag'},
                },
              ],
            }),
            200,
          );
        });
        final api = _createApi(client);

        final albums = await api.getRecentlyAddedAlbums(
          address: JellyfinServerAddress.parse('http://music.local:8096'),
          session: const JellyfinSession(
            accessToken: 'private-access-token',
            userId: 'user-id',
            userName: 'listener',
          ),
        );

        expect(albums, hasLength(1));
        expect(albums.single.title, 'Real Album');
        expect(albums.single.artist, 'Real Artist');
        expect(albums.single.artworkBytes, isNull);
        expect(
          await api.getArtwork(
            address: JellyfinServerAddress.parse('http://music.local:8096'),
            session: const JellyfinSession(
              accessToken: 'private-access-token',
              userId: 'user-id',
              userName: 'listener',
            ),
            itemId: albums.single.id,
            imageTag: albums.single.imageTag!,
          ),
          [1, 2, 3],
        );
        api.close();
      },
    );

    test(
      'unknown artwork tags resolve current song and album covers without caching a miss',
      () async {
        var available = false;
        final paths = <String>[];
        final api = _createApi(
          MockClient((request) async {
            paths.add(request.url.path);
            expect(
              request.headers['authorization'],
              contains('Token="private-access-token"'),
            );
            if (request.url.path.endsWith('/Images/Primary')) {
              expect(request.url.path, '/Items/album-id/Images/Primary');
              return http.Response.bytes([1, 2, 3], 200);
            }
            expect(request.url.path, '/Users/user-id/Items/song-id');
            return http.Response(
              jsonEncode({
                'Id': 'song-id',
                'AlbumId': 'album-id',
                if (available) 'AlbumPrimaryImageTag': 'fresh-cover',
              }),
              200,
            );
          }),
        );
        Future<List<int>?> load() => api.getArtwork(
          address: JellyfinServerAddress.parse('https://music.example'),
          session: const JellyfinSession(
            accessToken: 'private-access-token',
            userId: 'user-id',
            userName: 'listener',
          ),
          itemId: 'song-id',
          imageTag: null,
        );
        expect(await load(), isNull);
        available = true;
        expect(await load(), [1, 2, 3]);
        expect(paths, [
          '/Users/user-id/Items/song-id',
          '/Users/user-id/Items/song-id',
          '/Items/album-id/Images/Primary',
        ]);
        api.close();
      },
    );

    test('validates a restored session without a token URL', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://music.example/Users/Me');
        expect(request.url.query, isNot(contains('private-access-token')));
        expect(
          request.headers['authorization'],
          contains('Token="private-access-token"'),
        );
        return http.Response(
          jsonEncode({'Id': 'user-id', 'Name': 'listener'}),
          200,
        );
      });
      final api = _createApi(client);

      await api.validateSession(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
      );

      api.close();
    });

    test('loads a sorted album page with its total count', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['SortBy'], 'SortName');
        expect(request.url.queryParameters['StartIndex'], '24');
        expect(request.url.queryParameters['Limit'], '24');
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Id': 'album-id',
                'Name': 'Real Album',
                'AlbumArtist': 'Real Artist',
                'ProductionYear': 2026,
              },
            ],
            'TotalRecordCount': 49,
          }),
          200,
        );
      });
      final api = _createApi(client);

      final page = await api.getAlbums(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        sort: AlbumSort.title,
        startIndex: 24,
        limit: 24,
      );

      expect(page.totalCount, 49);
      expect(page.albums.single.year, 2026);
      api.close();
    });

    test('loads ordered tracks for an album', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['ParentId'], 'album-id');
        expect(request.url.queryParameters['IncludeItemTypes'], 'Audio');
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Id': 'track-id',
                'Name': 'Real Track',
                'Artists': ['Earth, Wind & Fire', 'Guest'],
                'IndexNumber': 1,
                'ParentIndexNumber': 1,
                'RunTimeTicks': 1920000000,
              },
            ],
          }),
          200,
        );
      });
      final api = _createApi(client);

      final tracks = await api.getAlbumTracks(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        albumId: 'album-id',
      );

      expect(tracks.single.title, 'Real Track');
      expect(tracks.single.artist, 'Earth, Wind & Fire; Guest');
      expect(tracks.single.duration, const Duration(minutes: 3, seconds: 12));
      api.close();
    });

    test('loads a paged alphabetical song library', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/Users/user-id/Items');
        expect(request.url.queryParameters['IncludeItemTypes'], 'Audio');
        expect(request.url.queryParameters['SortBy'], 'SortName');
        expect(request.url.queryParameters['StartIndex'], '100');
        expect(request.url.queryParameters['Limit'], '100');
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Id': 'song-id',
                'Name': 'A Library Song',
                'Artists': ['Real Artist'],
                'Album': 'Real Album',
                'RunTimeTicks': 1850000000,
              },
            ],
            'TotalRecordCount': 201,
          }),
          200,
        );
      });
      final api = _createApi(client);

      final page = await api.getSongs(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        startIndex: 100,
        limit: 100,
      );

      expect(page.totalCount, 201);
      expect(page.songs.single.track.title, 'A Library Song');
      expect(page.songs.single.track.artist, 'Real Artist');
      expect(page.songs.single.album, 'Real Album');
      expect(
        page.songs.single.track.duration,
        const Duration(minutes: 3, seconds: 5),
      );
      api.close();
    });

    test('loads a paged alphabetical artist library', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/Artists');
        expect(request.url.queryParameters['UserId'], 'user-id');
        expect(request.url.queryParameters['SortBy'], 'SortName');
        expect(request.url.queryParameters['StartIndex'], '48');
        expect(request.url.queryParameters['Limit'], '48');
        return http.Response(
          jsonEncode({
            'Items': [
              {'Id': 'artist-id', 'Name': 'Real Artist'},
            ],
            'TotalRecordCount': 97,
          }),
          200,
        );
      });
      final api = _createApi(client);

      final page = await api.getArtists(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        startIndex: 48,
        limit: 48,
      );

      expect(page.totalCount, 97);
      expect(page.artists.single.name, 'Real Artist');
      api.close();
    });

    test('loads albums belonging to one album artist', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/Users/user-id/Items');
        expect(request.url.queryParameters['IncludeItemTypes'], 'MusicAlbum');
        expect(request.url.queryParameters['AlbumArtistIds'], 'artist-id');
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Id': 'album-id',
                'Name': 'Artist Album',
                'AlbumArtist': 'Real Artist',
                'ProductionYear': 2025,
              },
            ],
          }),
          200,
        );
      });
      final api = _createApi(client);

      final albums = await api.getArtistAlbums(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        artistId: 'artist-id',
      );

      expect(albums.single.title, 'Artist Album');
      expect(albums.single.artist, 'Real Artist');
      expect(albums.single.year, 2025);
      api.close();
    });

    test('searches albums and songs with one authenticated request', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/Users/user-id/Items');
        expect(request.url.queryParameters['SearchTerm'], 'real');
        expect(
          request.url.queryParameters['IncludeItemTypes'],
          'MusicAlbum,Audio',
        );
        expect(request.url.query, isNot(contains('private-access-token')));
        expect(
          request.headers['authorization'],
          contains('Token="private-access-token"'),
        );
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Type': 'MusicAlbum',
                'Id': 'album-id',
                'Name': 'Real Album',
                'AlbumArtist': 'Real Artist',
                'ProductionYear': 2026,
              },
              {
                'Type': 'Audio',
                'Id': 'track-id',
                'Name': 'Real Song',
                'Artists': ['Real Artist'],
                'RunTimeTicks': 1250000000,
              },
            ],
          }),
          200,
        );
      });
      final api = _createApi(client);

      final results = await api.searchLibrary(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        query: ' real ',
      );

      expect(results.albums.single.title, 'Real Album');
      expect(results.albums.single.year, 2026);
      expect(results.tracks.single.track.title, 'Real Song');
      expect(
        results.tracks.single.track.duration,
        const Duration(minutes: 2, seconds: 5),
      );
      api.close();
    });

    test('loads synchronized lyrics without exposing the token', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/Audio/track-id/Lyrics');
        expect(request.url.query, isNot(contains('private-access-token')));
        expect(
          request.headers['authorization'],
          contains('Token="private-access-token"'),
        );
        return http.Response(
          jsonEncode({
            'Metadata': {'IsSynced': true},
            'Lyrics': [
              {'Text': 'First remembered line', 'Start': 108900000},
              {'Text': 'Second remembered line', 'Start': 145800000},
            ],
          }),
          200,
        );
      });
      final api = _createApi(client);

      final lyrics = await api.getLyrics(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        trackId: 'track-id',
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynchronized, isTrue);
      expect(lyrics.lines.first.text, 'First remembered line');
      expect(
        lyrics.lines.first.start,
        const Duration(seconds: 10, milliseconds: 890),
      );
      api.close();
    });

    test('returns unavailable when Jellyfin has no lyrics', () async {
      final api = _createApi(
        MockClient((_) async => http.Response('not available', 404)),
      );

      final lyrics = await api.getLyrics(
        address: JellyfinServerAddress.parse('https://music.example'),
        session: const JellyfinSession(
          accessToken: 'private-access-token',
          userId: 'user-id',
          userName: 'listener',
        ),
        trackId: 'track-id',
      );

      expect(lyrics, isNull);
      api.close();
    });

    test('reports HTTP status without exposing a private response', () async {
      final client = MockClient(
        (_) async => http.Response('private server response', 401),
      );
      final api = _createApi(client);

      await expectLater(
        api.authenticate(
          address: JellyfinServerAddress.parse('http://music.local:8096'),
          userName: 'listener',
          password: 'wrong-password',
        ),
        throwsA(
          isA<JellyfinConnectionException>()
              .having((error) => error.statusCode, 'status code', 401)
              .having(
                (error) => error.message,
                'safe message',
                allOf(contains('HTTP 401'), isNot(contains('private server'))),
              ),
        ),
      );
      api.close();
    });

    test('rejects malformed successful responses safely', () async {
      final client = MockClient((_) async => http.Response('not json', 200));
      final api = _createApi(client);

      await expectLater(
        api.getPublicServerInfo(
          JellyfinServerAddress.parse('http://music.local:8096'),
        ),
        throwsA(
          isA<JellyfinConnectionException>().having(
            (error) => error.message,
            'message',
            isNot(contains('not json')),
          ),
        ),
      );
      api.close();
    });
  });
}

HttpJellyfinApi _createApi(http.Client client) {
  return HttpJellyfinApi(
    client: client,
    identity: const JellyfinClientIdentity(
      clientName: 'gaze',
      deviceName: 'test desktop',
      deviceId: 'test-device-id',
      version: '0.1.0',
    ),
  );
}
