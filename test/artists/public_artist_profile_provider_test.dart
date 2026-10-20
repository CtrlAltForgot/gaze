import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gaze/artists/public_artist_profile_provider.dart';
import 'package:gaze/storage/local_content_cache.dart';

const id = '11111111-1111-1111-1111-111111111111';
void main() {
  test(
    'corroborates a recording, enriches linked identity, and reuses the cache',
    () async {
      final cache = SqliteLocalContentCache.inMemory();
      addTearDown(cache.dispose);
      final requests = <Uri>[];
      final provider = PublicArtistProfileProvider(
        MockClient((r) async {
          requests.add(r.url);
          expect(
            r.headers.keys.map((s) => s.toLowerCase()),
            isNot(contains('authorization')),
          );
          dynamic data;
          switch (r.url.host) {
            case 'musicbrainz.org':
              data = r.url.path.endsWith('recording')
                  ? {
                      'recordings': [
                        {
                          'title': 'Hit',
                          'artist-credit': [
                            {
                              'artist': {'id': id, 'name': 'Singer'},
                            },
                          ],
                        },
                      ],
                    }
                  : {
                      'type': 'Person',
                      'begin-area': {'name': 'Tacoma'},
                      'area': {'name': 'United States'},
                      'life-span': {'begin': '1990-01-01'},
                      'relations': [
                        {
                          'type': 'wikidata',
                          'url': {
                            'resource': 'https://www.wikidata.org/wiki/Q123',
                          },
                        },
                      ],
                    };
            case 'api.listenbrainz.org':
              data = [
                {
                  'artist_mbids': [id],
                  'recording_name': 'Hit',
                  'total_listen_count': 99,
                },
              ];
            case 'www.wikidata.org':
              data = {
                'entities': {
                  'Q123': {
                    'sitelinks': {
                      'enwiki': {'title': 'Singer'},
                    },
                  },
                },
              };
            case 'en.wikipedia.org':
              data = {
                'type': 'standard',
                'wikibase_item': 'Q123',
                'extract': 'A short biography.',
              };
            default:
              throw StateError('Unexpected host');
          }
          return http.Response(jsonEncode(data), 200);
        }),
        cache: cache,
        musicBrainzInterval: Duration.zero,
      );
      final p = await provider.find('Singer', recordings: ['Hit']);
      expect(p!.biography, 'A short biography.');
      expect(p.origin, 'Tacoma, United States');
      expect(p.popularTitles, ['Hit']);
      final count = requests.length;
      expect((await provider.find('Singer'))!.musicBrainzId, id);
      expect(requests.length, count);
    },
  );
  test(
    'ambiguous names are left unmatched instead of selecting the first',
    () async {
      final p = PublicArtistProfileProvider(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'count': 2,
              'artists': [
                {'id': id, 'name': 'Same'},
                {'id': '22222222-2222-2222-2222-222222222222', 'name': 'Same'},
              ],
            }),
            200,
          ),
        ),
        cache: const DisabledLocalContentCache(),
        musicBrainzInterval: Duration.zero,
      );
      expect(await p.find('Same'), isNull);
    },
  );
  test(
    'mismatched Wikipedia identity and optional provider failure do not invent a profile',
    () async {
      final p = PublicArtistProfileProvider(
        MockClient((r) async {
          dynamic data;
          if (r.url.host == 'api.listenbrainz.org')
            return http.Response('{}', 503);
          if (r.url.path.endsWith('/artist'))
            data = {
              'count': 1,
              'artists': [
                {'id': id, 'name': 'Singer'},
              ],
            };
          else if (r.url.host == 'musicbrainz.org')
            data = {
              'type': 'Group',
              'relations': [
                {
                  'type': 'wikidata',
                  'url': {'resource': 'https://www.wikidata.org/wiki/Q123'},
                },
              ],
            };
          else if (r.url.host == 'www.wikidata.org')
            data = {
              'entities': {
                'Q123': {
                  'sitelinks': {
                    'enwiki': {'title': 'Singer'},
                  },
                },
              },
            };
          else
            data = {'wikibase_item': 'Q999', 'extract': 'Wrong person'};
          return http.Response(jsonEncode(data), 200);
        }),
        cache: const DisabledLocalContentCache(),
        musicBrainzInterval: Duration.zero,
      );
      final profile = await p.find('Singer');
      expect(profile!.biography, isNull);
      expect(profile.popularTitles, isEmpty);
    },
  );
}
