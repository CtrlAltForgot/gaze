import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/http_jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const session = JellyfinSession(
  accessToken: 'test-token',
  userId: 'listener-id',
  userName: 'listener',
);
final address = JellyfinServerAddress.parse('https://music.example/jellyfin');
HttpJellyfinApi api(MockClient client) => HttpJellyfinApi(
  client: client,
  identity: const JellyfinClientIdentity(deviceId: 'test-device'),
);
void main() {
  test(
    'song metadata pagination does not wait for artwork and uses the raw server offset',
    () async {
      var requests = 0;
      final adapter = api(
        MockClient((request) async {
          requests++;
          expect(request.url.path, '/jellyfin/Users/listener-id/Items');
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 4,
              'Items': [
                {
                  'Id': 'one',
                  'Name': 'One',
                  'Type': 'Audio',
                  'AlbumId': 'album',
                  'AlbumPrimaryImageTag': 'tag',
                  'Artists': ['Artist'],
                },
                {'Name': 'invalid'},
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(adapter.close);
      final page = await adapter.getSongs(
        address: address,
        session: session,
        startIndex: 0,
        limit: 2,
      );
      expect(requests, 1);
      expect(page.songs.length, 1);
      expect(page.nextStartIndex, 2);
      expect(page.songs.single.albumId, 'album');
      expect(page.songs.single.artworkBytes, isNull);
    },
  );
  test(
    'playlist listing uses authenticated user context and track requests preserve order and duplicates',
    () async {
      final adapter = api(
        MockClient((request) async {
          expect(request.headers['authorization'], contains('test-token'));
          expect(request.url.query, isNot(contains('test-token')));
          if (request.url.path.endsWith('/Items') &&
              !request.url.path.contains('/Playlists/')) {
            expect(request.url.queryParameters['IncludeItemTypes'], 'Playlist');
            return http.Response(
              jsonEncode({
                'TotalRecordCount': 1,
                'Items': [
                  {
                    'Id': 'mix',
                    'Name': 'Mix',
                    'MediaType': 'Audio',
                    'ChildCount': 3,
                  },
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/jellyfin/Playlists/mix/Items');
          expect(request.url.queryParameters['UserId'], 'listener-id');
          expect(request.url.queryParameters.containsKey('SortBy'), isFalse);
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 3,
              'Items': [
                {'Id': 'two', 'Name': 'Two', 'Type': 'Audio'},
                {'Id': 'one', 'Name': 'One', 'Type': 'Audio'},
                {'Id': 'two', 'Name': 'Two', 'Type': 'Audio'},
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(adapter.close);
      expect(
        (await adapter.getPlaylists(
          address: address,
          session: session,
          startIndex: 0,
          limit: 48,
        )).playlists.single.title,
        'Mix',
      );
      final tracks = await adapter.getPlaylistTracks(
        address: address,
        session: session,
        playlistId: 'mix',
        startIndex: 0,
        limit: 100,
      );
      expect(tracks.songs.map((s) => s.track.id), ['two', 'one', 'two']);
    },
  );
}
