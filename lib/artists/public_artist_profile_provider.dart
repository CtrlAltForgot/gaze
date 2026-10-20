import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../library/artist_credits.dart';
import '../library/artist_profile.dart';
import '../storage/local_content_cache.dart';
import 'artist_profile_provider.dart';

/// Public metadata only; never shares server addresses, credentials or audio.
/// One lookup on opening a profile, with disk caching and MusicBrainz pacing.
class PublicArtistProfileProvider implements ArtistProfileProvider {
  PublicArtistProfileProvider(
    this.client, {
    required this.cache,
    this.musicBrainzInterval = const Duration(milliseconds: 1100),
  });
  final http.Client client;
  final LocalContentCache cache;
  final Duration musicBrainzInterval;
  static const _headers = {
    'User-Agent': 'gaze/1.0 (https://github.com/CtrlAltForgot/gaze)',
    'Accept': 'application/json',
  };
  final Map<String, Future<ArtistProfile?>> _pending = {};
  Future<void> _mbTurn = Future.value();
  DateTime _nextMb = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<ArtistProfile?> find(
    String name, {
    List<String> recordings = const [],
  }) {
    final key = artistKey(name);
    return _pending.putIfAbsent(
      key,
      () => _find(name, recordings).whenComplete(() {
        _pending.remove(key);
      }),
    );
  }

  Future<dynamic> _get(Uri uri) async {
    if (uri.host == 'musicbrainz.org') {
      final previous = _mbTurn;
      final turn = Completer<void>();
      _mbTurn = turn.future;
      await previous;
      try {
        final delay = _nextMb.difference(DateTime.now());
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        _nextMb = DateTime.now().add(musicBrainzInterval);
      } finally {
        turn.complete();
      }
    }
    final response = await client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 2 * 1024 * 1024)
      throw const FormatException(
        'Public artist information is temporarily unavailable.',
      );
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  String _query(String value) =>
      value.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ').trim();
  Uri _mb(String path, [Map<String, String> params = const {}]) =>
      Uri.https('musicbrainz.org', '/ws/2/$path', {'fmt': 'json', ...params});

  Future<String?> _identify(String name, List<String> recordings) async {
    // A matching recording corroborates an artist when several share a name.
    for (final title in recordings.take(2)) {
      final result =
          await _get(
                _mb('recording', {
                  'query':
                      'artist:"${_query(name)}" AND recording:"${_query(title)}"',
                  'limit': '25',
                }),
              )
              as Map;
      final ids = <String>{};
      for (final recording in result['recordings'] as List? ?? []) {
        if (recordingKey(recording['title'] as String? ?? '') !=
            recordingKey(title))
          continue;
        for (final credit in recording['artist-credit'] as List? ?? []) {
          final artist = credit['artist'];
          if (artist is Map &&
              artistKey(artist['name'] as String? ?? '') == artistKey(name) &&
              artist['id'] is String)
            ids.add(artist['id'] as String);
        }
      }
      if (ids.length == 1) return ids.single;
    }
    final result =
        await _get(
              _mb('artist', {
                'query': 'artist:"${_query(name)}"',
                'limit': '100',
              }),
            )
            as Map;
    if ((result['count'] as int? ?? 0) > 100) return null;
    final matches = (result['artists'] as List? ?? [])
        .where((a) => artistKey(a['name'] as String? ?? '') == artistKey(name))
        .toList();
    return matches.length == 1 ? matches.single['id'] as String? : null;
  }

  Future<ArtistProfile?> _find(String name, List<String> recordings) async {
    final key = 'public-artist-v1:${artistKey(name)}';
    try {
      final saved = await cache.read(key);
      if (saved != null)
        return ArtistProfile.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
        );
    } catch (_) {}
    final id = await _identify(name, recordings);
    if (id == null || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) return null;
    final data = await _get(_mb('artist/$id', {'inc': 'url-rels'})) as Map;
    final areas = <String>{};
    for (final field in ['begin-area', 'area']) {
      final area = data[field];
      if (area is Map && area['name'] is String)
        areas.add(area['name'] as String);
    }
    String? bio, wikiUrl, photo, photoCredit, photoSource;
    final titles = <String>[];
    // Each optional enrichment may fail independently without hiding library music.
    try {
      final popular = await _get(
        Uri.https(
          'api.listenbrainz.org',
          '/1/popularity/top-recordings-for-artist/$id',
        ),
      );
      if (popular is List) {
        final ranked =
            popular
                .whereType<Map>()
                .where(
                  (r) =>
                      r['recording_name'] is String &&
                      (r['artist_mbids'] as List? ?? []).contains(id),
                )
                .toList()
              ..sort(
                (a, b) => ((b['total_listen_count'] as num?) ?? 0).compareTo(
                  (a['total_listen_count'] as num?) ?? 0,
                ),
              );
        titles.addAll(ranked.map((r) => r['recording_name'] as String));
      }
    } catch (_) {}
    try {
      String? qid;
      for (final relation in data['relations'] as List? ?? []) {
        if (relation['type'] != 'wikidata') continue;
        final uri = Uri.tryParse(relation['url']?['resource'] as String? ?? '');
        if (uri != null &&
            (uri.host == 'www.wikidata.org' || uri.host == 'wikidata.org')) {
          final candidate = uri.pathSegments.last;
          if (RegExp(r'^Q\d+$').hasMatch(candidate)) qid = candidate;
        }
      }
      if (qid != null) {
        final entity =
            await _get(
                  Uri.https(
                    'www.wikidata.org',
                    '/wiki/Special:EntityData/$qid.json',
                  ),
                )
                as Map;
        final title =
            entity['entities']?[qid]?['sitelinks']?['enwiki']?['title'];
        if (title is String) {
          final summary =
              await _get(
                    Uri.https(
                      'en.wikipedia.org',
                      '/api/rest_v1/page/summary/$title',
                    ),
                  )
                  as Map;
          if (summary['type'] != 'disambiguation' &&
              summary['wikibase_item'] == qid) {
            bio = summary['extract'] as String?;
            wikiUrl = Uri.https(
              'en.wikipedia.org',
              '/wiki/${title.replaceAll(' ', '_')}',
            ).toString();
            final thumb = Uri.tryParse(
              summary['thumbnail']?['source'] as String? ?? '',
            );
            final original = Uri.tryParse(
              summary['originalimage']?['source'] as String? ?? '',
            );
            if (thumb?.host == 'upload.wikimedia.org' &&
                thumb?.scheme == 'https' &&
                original != null &&
                original.path.contains('/commons/')) {
              final file = Uri.decodeComponent(original.pathSegments.last);
              final credit =
                  await _get(
                        Uri.https('commons.wikimedia.org', '/w/api.php', {
                          'action': 'query',
                          'format': 'json',
                          'prop': 'imageinfo',
                          'iiprop': 'extmetadata',
                          'titles': 'File:$file',
                        }),
                      )
                      as Map;
              final pages = credit['query']?['pages'];
              if (pages is Map && pages.isNotEmpty) {
                final info = (pages.values.first['imageinfo'] as List?)?.first;
                final meta = info?['extmetadata'];
                String clean(dynamic v) => (v as String? ?? '')
                    .replaceAll(RegExp(r'<[^>]*>'), '')
                    .replaceAll('&amp;', '&')
                    .trim();
                final author = clean(meta?['Artist']?['value']);
                final license = clean(meta?['LicenseShortName']?['value']);
                if (author.isNotEmpty && license.isNotEmpty) {
                  photo = thumb.toString();
                  photoCredit = '$author · $license';
                  photoSource = Uri.https(
                    'commons.wikimedia.org',
                    '/wiki/File:$file',
                  ).toString();
                }
              }
            }
          }
        }
      }
    } catch (_) {}
    final profile = ArtistProfile(
      musicBrainzId: id,
      origin: areas.isEmpty ? null : areas.join(', '),
      type: data['type'] as String?,
      born: data['life-span']?['begin'] as String?,
      ended: data['life-span']?['ended'] == true,
      biography: bio,
      wikipediaUrl: wikiUrl,
      photoUrl: photo,
      photoCredit: photoCredit,
      photoSource: photoSource,
      popularTitles: titles,
    );
    try {
      await cache.write(
        key,
        jsonEncode(profile.toJson()),
        ttl: const Duration(days: 7),
      );
    } catch (_) {}
    return profile;
  }
}
