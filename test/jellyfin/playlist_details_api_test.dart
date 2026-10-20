import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/http_jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);
Map<String, dynamic> _item() => {
  'Id': 'mix',
  'Type': 'Playlist',
  'Name': 'Evening',
  'Overview': 'Old description',
  'ChildCount': 4,
  'ImageTags': {'Primary': 'old-cover'},
  'LockData': true,
  'LockedFields': ['Genres'],
  'Genres': ['Ambient'],
  'ProviderIds': {'ExistingProvider': 'kept'},
  'Tags': ['private-note'],
  'DateCreated': '2025-05-02T17:00:00Z',
  'ForcedSortName': 'Sort me here',
  'UserData': {'IsFavorite': true},
};

void main() {
  test(
    'detail reads include the canonical description and cover tag',
    () async {
      final api = adapter(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/jellyfin/Users/owner/Items/mix');
          return http.Response(jsonEncode(_item()), 200);
        }),
      );
      addTearDown(api.close);
      final result = await api.getPlaylistDetails(
        address: address,
        session: owner,
        playlistId: 'mix',
      );
      expect(result.title, 'Evening');
      expect(result.description, 'Old description');
      expect(result.imageTag, 'old-cover');
      expect(result.trackCount, 4);
    },
  );

  test(
    'details preserve complete metadata, upload base64, and return server state',
    () async {
      var item = _item();
      final writes = <String>[];
      final api = adapter(
        MockClient((request) async {
          expect(request.headers['authorization'], contains('owner-token'));
          expect(request.url.query, isNot(contains('owner-token')));
          if (request.url.path.endsWith('/Users/owner')) {
            return http.Response('{"CanEdit":true}', 200);
          }
          if (request.method == 'GET') {
            return http.Response(jsonEncode(item), 200);
          }
          writes.add(request.url.path);
          if (request.url.path.endsWith('/Images/Primary')) {
            expect(request.headers['content-type'], startsWith('image/png'));
            expect(base64Decode(request.body), _png);
            item['ImageTags'] = {'Primary': 'server-new-cover'};
          } else {
            expect(request.url.path, '/jellyfin/Items/mix');
            final updated = jsonDecode(request.body) as Map<String, dynamic>;
            expect(updated, {
              ..._item(),
              'Name': 'New title',
              'Overview': 'New description',
            });
            expect(updated.containsKey('Ids'), false);
            expect(updated.containsKey('Users'), false);
            expect(updated.containsKey('IsPublic'), false);
            item = updated;
          }
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      final result = await api.updatePlaylistDetails(
        address: address,
        session: owner,
        playlistId: 'mix',
        name: '  New title  ',
        description: 'New description',
        imageBytes: _png,
        imageMimeType: 'image/png',
      );
      expect(writes, [
        '/jellyfin/Items/mix',
        '/jellyfin/Items/mix/Images/Primary',
      ]);
      expect(result.title, 'New title');
      expect(result.description, 'New description');
      expect(result.imageTag, 'server-new-cover');
      expect(result.trackCount, 4);
    },
  );

  test(
    'a name-only edit does not require elevated metadata access or resend fields',
    () async {
      var item = _item();
      final api = adapter(
        MockClient((request) async {
          if (request.url.path.endsWith('/Users/owner')) {
            return http.Response('{"CanEdit":true}', 200);
          }
          if (request.method == 'POST') {
            expect(request.url.path, '/jellyfin/Playlists/mix');
            expect(jsonDecode(request.body), {'Name': 'Renamed'});
            item['Name'] = 'Renamed';
            return http.Response('', 204);
          }
          return http.Response(jsonEncode(item), 200);
        }),
      );
      addTearDown(api.close);
      final result = await api.updatePlaylistDetails(
        address: address,
        session: owner,
        playlistId: 'mix',
        name: 'Renamed',
        description: 'Old description',
      );
      expect(result.title, 'Renamed');
      expect(result.imageTag, 'old-cover');
    },
  );

  test('image-only edit leaves name and metadata untouched', () async {
    var item = _item();
    final api = adapter(
      MockClient((request) async {
        if (request.url.path.endsWith('/Users/owner')) {
          return http.Response('{"CanEdit":true}', 200);
        }
        if (request.method == 'POST') {
          expect(request.url.path, '/jellyfin/Items/mix/Images/Primary');
          item['ImageTags'] = {'Primary': 'image-only'};
          return http.Response('', 204);
        }
        return http.Response(jsonEncode(item), 200);
      }),
    );
    addTearDown(api.close);
    final result = await api.updatePlaylistDetails(
      address: address,
      session: owner,
      playlistId: 'mix',
      name: 'Evening',
      description: 'Old description',
      imageBytes: _png,
      imageMimeType: 'image/png',
    );
    expect(result.imageTag, 'image-only');
    expect(result.title, 'Evening');
  });

  test(
    'permission and object type checks prevent writes to unauthorized or media items',
    () async {
      for (final permitted in [false, true]) {
        var writes = 0;
        final api = adapter(
          MockClient((request) async {
            if (request.method != 'GET') writes++;
            if (request.url.path.endsWith('/Users/owner')) {
              return http.Response(jsonEncode({'CanEdit': permitted}), 200);
            }
            return http.Response(
              jsonEncode({..._item(), 'Type': 'Audio'}),
              200,
            );
          }),
        );
        addTearDown(api.close);
        await expectLater(
          api.updatePlaylistDetails(
            address: address,
            session: owner,
            playlistId: 'mix',
            name: 'No',
            description: '',
          ),
          throwsA(isA<JellyfinConnectionException>()),
        );
        expect(writes, 0);
      }
    },
  );

  test(
    'invalid descriptions, IDs and cover bytes fail before any network request',
    () async {
      var requests = 0;
      final api = adapter(
        MockClient((_) async {
          requests++;
          return http.Response('', 500);
        }),
      );
      addTearDown(api.close);
      for (final values in [
        (id: 'mix', name: '', description: '', bytes: null, mime: null),
        (id: '../song', name: 'Name', description: '', bytes: null, mime: null),
        (
          id: 'mix',
          name: 'Name',
          description: 'x' * 2001,
          bytes: null,
          mime: null,
        ),
        (
          id: 'mix',
          name: 'Name',
          description: '',
          bytes: Uint8List(1),
          mime: 'image/png',
        ),
        (
          id: 'mix',
          name: 'Name',
          description: '',
          bytes: _png,
          mime: 'image/jpeg',
        ),
        (
          id: 'mix',
          name: 'Name',
          description: '',
          bytes: Uint8List(10 * 1024 * 1024 + 1),
          mime: 'image/png',
        ),
      ]) {
        await expectLater(
          api.updatePlaylistDetails(
            address: address,
            session: owner,
            playlistId: values.id,
            name: values.name,
            description: values.description,
            imageBytes: values.bytes,
            imageMimeType: values.mime,
          ),
          throwsA(isA<JellyfinConnectionException>()),
        );
      }
      expect(requests, 0);
    },
  );

  test(
    'failed cover after saved details reports current metadata without rollback',
    () async {
      var item = _item();
      var metadataWrites = 0;
      final api = adapter(
        MockClient((request) async {
          if (request.url.path.endsWith('/Users/owner')) {
            return http.Response('{"CanEdit":true}', 200);
          }
          if (request.method == 'GET')
            return http.Response(jsonEncode(item), 200);
          if (request.url.path.endsWith('/Images/Primary')) {
            return http.Response('private response with token', 403);
          }
          metadataWrites++;
          item = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.updatePlaylistDetails(
          address: address,
          session: owner,
          playlistId: 'mix',
          name: 'Saved title',
          description: 'Saved description',
          imageBytes: _png,
          imageMimeType: 'image/png',
        ),
        throwsA(
          isA<JellyfinPlaylistUpdateException>()
              .having(
                (e) => e.savedPlaylist?.title,
                'confirmed title',
                'Saved title',
              )
              .having(
                (e) => e.savedPlaylist?.imageTag,
                'retained cover',
                'old-cover',
              )
              .having(
                (e) => e.message,
                'safe partial save error',
                allOf(
                  contains('details were saved'),
                  contains('permission'),
                  isNot(contains('private response')),
                ),
              ),
        ),
      );
      expect(metadataWrites, 1);
    },
  );

  test(
    'failed metadata update never starts image upload and preserves confirmed data',
    () async {
      var imageWrites = 0;
      final api = adapter(
        MockClient((request) async {
          if (request.url.path.endsWith('/Users/owner')) {
            return http.Response('{"CanEdit":true}', 200);
          }
          if (request.method == 'GET')
            return http.Response(jsonEncode(_item()), 200);
          if (request.url.path.endsWith('/Images/Primary')) imageWrites++;
          return http.Response('private details', 403);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.updatePlaylistDetails(
          address: address,
          session: owner,
          playlistId: 'mix',
          name: 'New title',
          description: 'New description',
          imageBytes: _png,
          imageMimeType: 'image/png',
        ),
        throwsA(
          isA<JellyfinPlaylistUpdateException>()
              .having((e) => e.savedPlaylist?.title, 'old title', 'Evening')
              .having(
                (e) => e.message,
                'permission error',
                contains('descriptions'),
              ),
        ),
      );
      expect(imageWrites, 0);
    },
  );

  test(
    'a timed-out upload is unconfirmed even if local text was saved',
    () async {
      var item = _item();
      final api = adapter(
        MockClient((request) async {
          if (request.url.path.endsWith('/Users/owner')) {
            return http.Response('{"CanEdit":true}', 200);
          }
          if (request.method == 'GET')
            return http.Response(jsonEncode(item), 200);
          if (request.url.path.endsWith('/Images/Primary'))
            throw http.ClientException('secret detail');
          item['Name'] = 'Saved title';
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.updatePlaylistDetails(
          address: address,
          session: owner,
          playlistId: 'mix',
          name: 'Saved title',
          description: 'Old description',
          imageBytes: _png,
          imageMimeType: 'image/png',
        ),
        throwsA(
          isA<JellyfinPlaylistUpdateException>()
              .having(
                (e) => e.savedPlaylist?.title,
                'confirmed title',
                'Saved title',
              )
              .having(
                (e) => e.message,
                'honest unknown state',
                allOf(
                  contains('Could not confirm'),
                  isNot(contains('secret detail')),
                ),
              ),
        ),
      );
    },
  );

  test(
    'successful writes with failed readback are reported as saved but unrefreshed',
    () async {
      var wrote = false;
      final api = adapter(
        MockClient((request) async {
          if (request.url.path.endsWith('/Users/owner')) {
            return http.Response('{"CanEdit":true}', 200);
          }
          if (request.method == 'POST') {
            wrote = true;
            return http.Response('', 204);
          }
          return wrote
              ? http.Response('', 503)
              : http.Response(jsonEncode(_item()), 200);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.updatePlaylistDetails(
          address: address,
          session: owner,
          playlistId: 'mix',
          name: 'New title',
          description: 'Old description',
        ),
        throwsA(
          isA<JellyfinPlaylistUpdateException>()
              .having(
                (e) => e.savedPlaylist,
                'no invented current state',
                isNull,
              )
              .having(
                (e) => e.message,
                'saved status',
                contains('changes were saved'),
              ),
        ),
      );
    },
  );
}
