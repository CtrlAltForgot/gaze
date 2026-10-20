import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/http_jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/library/track_summary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../widget_test.dart' as fixtures;

const owner = JellyfinSession(
  accessToken: 'owner-token',
  userId: 'owner',
  userName: 'listener',
);
final address = JellyfinServerAddress.parse('https://music.example/jellyfin');
HttpJellyfinApi adapter(MockClient client) => HttpJellyfinApi(
  client: client,
  identity: const JellyfinClientIdentity(deviceId: 'device'),
);
void main() {
  test(
    'private account playlists are stored on the server and returned to an independent client',
    () async {
      final saved = <Map<String, dynamic>>[];
      Future<http.Response> server(http.Request request) async {
        expect(request.url.query, isNot(contains('owner-token')));
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['IsPublic'], false);
          expect(body['UserId'], 'owner');
          expect(body['MediaType'], 'Audio');
          expect(body['Ids'], ['track-one', 'track-one']);
          expect(body['Users'], isEmpty);
          saved.add({...body, 'Id': 'owned-playlist'});
          return http.Response(jsonEncode({'Id': 'owned-playlist'}), 200);
        }
        if (request.url.path.contains('/Playlists/'))
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 2,
              'Items': [
                {
                  'Id': 'track-one',
                  'Name': 'Song',
                  'Type': 'Audio',
                  'PlaylistItemId': 'entry-one',
                },
              ],
            }),
            200,
          );
        final rows = request.url.path.contains('/owner/')
            ? saved
            : <Map<String, dynamic>>[];
        return http.Response(
          jsonEncode({
            'TotalRecordCount': rows.length,
            'Items': rows
                .map(
                  (p) => {
                    'Id': p['Id'],
                    'Name': p['Name'],
                    'MediaType': 'Audio',
                    'ChildCount': 2,
                  },
                )
                .toList(),
          }),
          200,
        );
      }

      final desktop = adapter(MockClient(server));
      final secondDevice = adapter(MockClient(server));
      addTearDown(desktop.close);
      addTearDown(secondDevice.close);
      final created = await desktop.createPlaylist(
        address: address,
        session: owner,
        name: '  Evening  ',
        itemIds: ['track-one', 'track-one'],
      );
      expect(created.trackCount, 2);
      expect(
        (await secondDevice.getPlaylists(
          address: address,
          session: owner,
          startIndex: 0,
          limit: 48,
        )).playlists.single.title,
        'Evening',
      );
      const other = JellyfinSession(
        accessToken: 'other-token',
        userId: 'other',
        userName: 'other',
      );
      expect(
        (await secondDevice.getPlaylists(
          address: address,
          session: other,
          startIndex: 0,
          limit: 48,
        )).playlists,
        isEmpty,
      );
    },
  );
  test(
    'rename changes only the name and preserves membership and sharing',
    () async {
      final api = adapter(
        MockClient((request) async {
          expect(request.url.path, '/jellyfin/Playlists/mix');
          expect(jsonDecode(request.body), {'Name': 'Renamed'});
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      await api.renamePlaylist(
        address: address,
        session: owner,
        playlistId: 'mix',
        name: 'Renamed',
      );
    },
  );
  test(
    'duplicate tracks keep occurrence IDs and removal targets one occurrence',
    () async {
      final api = adapter(
        MockClient((request) async {
          if (request.method == 'DELETE') {
            expect(request.url.path, '/jellyfin/Playlists/mix/Items');
            expect(request.url.queryParameters, {'EntryIds': 'entry-two'});
            return http.Response('', 204);
          }
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 2,
              'Items': [
                {
                  'Id': 'track',
                  'Name': 'Song',
                  'Type': 'Audio',
                  'PlaylistItemId': 'entry-one',
                },
                {
                  'Id': 'track',
                  'Name': 'Song',
                  'Type': 'Audio',
                  'PlaylistItemId': 'entry-two',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final page = await api.getPlaylistTracks(
        address: address,
        session: owner,
        playlistId: 'mix',
        startIndex: 0,
        limit: 100,
      );
      expect(page.songs.map((s) => s.entryId), ['entry-one', 'entry-two']);
      await api.removePlaylistEntry(
        address: address,
        session: owner,
        playlistId: 'mix',
        entryId: page.songs.last.entryId!,
      );
    },
  );
  test(
    'playlist adds and moves use authenticated playlist-only routes',
    () async {
      final paths = <String>[];
      final api = adapter(
        MockClient((request) async {
          expect(request.headers['authorization'], contains('owner-token'));
          paths.add(request.url.path);
          if (request.url.path.endsWith('/Items'))
            expect(request.url.queryParameters, {
              'UserId': 'owner',
              'Ids': 'one,two',
            });
          expect(request.method, 'POST');
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      await api.addPlaylistSongs(
        address: address,
        session: owner,
        playlistId: 'mix',
        itemIds: ['one', 'two'],
      );
      await api.movePlaylistEntry(
        address: address,
        session: owner,
        playlistId: 'mix',
        entryId: 'entry-two',
        newIndex: 0,
      );
      expect(paths, [
        '/jellyfin/Playlists/mix/Items',
        '/jellyfin/Playlists/mix/Items/entry-two/Move/0',
      ]);
    },
  );
  test(
    'delete refuses media items before issuing any delete request',
    () async {
      var deletes = 0;
      final api = adapter(
        MockClient((request) async {
          if (request.method == 'DELETE') deletes++;
          return http.Response(jsonEncode({'Type': 'Audio'}), 200);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.deletePlaylist(
          address: address,
          session: owner,
          playlistId: 'song',
        ),
        throwsA(isA<JellyfinConnectionException>()),
      );
      expect(deletes, 0);
    },
  );
  test(
    'confirmed playlist deletion checks the object type then deletes just the playlist',
    () async {
      final paths = <String>[];
      final api = adapter(
        MockClient((request) async {
          paths.add('${request.method} ${request.url.path}');
          return request.method == 'GET'
              ? http.Response(jsonEncode({'Type': 'Playlist'}), 200)
              : http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      await api.deletePlaylist(
        address: address,
        session: owner,
        playlistId: 'mix',
      );
      expect(paths, [
        'GET /jellyfin/Users/owner/Items/mix',
        'DELETE /jellyfin/Items/mix',
      ]);
    },
  );
  test(
    'forbidden saves retain safe permission errors without private response data',
    () async {
      final api = adapter(
        MockClient((_) async => http.Response('private server response', 403)),
      );
      addTearDown(api.close);
      expect(
        await api.canEditPlaylist(
          address: address,
          session: owner,
          playlistId: 'mix',
        ),
        false,
      );
      await expectLater(
        api.renamePlaylist(
          address: address,
          session: owner,
          playlistId: 'mix',
          name: 'Name',
        ),
        throwsA(
          isA<JellyfinConnectionException>().having(
            (e) => e.message,
            'message',
            allOf(contains('permission'), isNot(contains('private server'))),
          ),
        ),
      );
    },
  );
  test('a stale playlist order is refreshed rather than overwritten', () async {
    final api = ChangedPlaylistApi();
    final ctl = JellyfinConnectionController(
      apiFactory: (_) => api,
      credentialStore: fixtures.FakeCredentialStore(),
    );
    addTearDown(ctl.dispose);
    await ctl.connect(
      serverAddress: 'https://music.example',
      userName: 'listener',
      password: 'test-password',
    );
    await expectLater(
      ctl.movePlaylistEntry(
        'mix',
        'new-entry',
        0,
        expectedEntries: ['old-entry'],
      ),
      throwsA(
        isA<JellyfinConnectionException>().having(
          (e) => e.message,
          'message',
          contains('another device'),
        ),
      ),
    );
    expect(api.moves, 0);
    await ctl.movePlaylistEntry(
      'mix',
      'new-entry',
      0,
      expectedEntries: ['new-entry'],
    );
    expect(api.moves, 1);
  });
}

class ChangedPlaylistApi extends fixtures.FakeJellyfinApi {
  int moves = 0;
  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) async => const SongPage(
    songs: [
      SongSummary(
        track: TrackSummary(
          id: 'track',
          title: 'Song',
          artist: 'Artist',
          duration: Duration(minutes: 3),
        ),
        album: 'Album',
        entryId: 'new-entry',
      ),
    ],
    totalCount: 1,
  );
  @override
  Future<void> movePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
    required int newIndex,
  }) async {
    moves++;
  }
}
