import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/library_search_results.dart';
import '../library/track_lyrics.dart';
import '../library/track_summary.dart';
import '../storage/artwork_cache.dart';
import 'jellyfin_api.dart';

class HttpJellyfinApi implements JellyfinApi {
  HttpJellyfinApi({
    required http.Client client,
    required JellyfinClientIdentity identity,
    this.artworkCache = const DisabledArtworkCache(),
    this.requestTimeout = const Duration(seconds: 12),
  }) : _client = client,
       _identity = identity {
    _validateIdentity(identity);
  }

  final http.Client _client;
  final JellyfinClientIdentity _identity;
  final ArtworkCache artworkCache;
  final Duration requestTimeout;

  @override
  JellyfinAudioStreamSource createDirectPlaySource({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
  }) {
    if (itemId.isEmpty || itemId.contains('/')) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an invalid track identifier.',
      );
    }
    return JellyfinAudioStreamSource(
      uri: address
          .endpoint('/Audio/$itemId/stream')
          .replace(queryParameters: const {'static': 'true'}),
      headers: _authenticatedHeaders(session),
    );
  }

  @override
  Future<void> reportPlayback({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required JellyfinPlaybackEvent event,
    required String itemId,
    required Duration position,
    required double volume,
    required bool paused,
  }) async {
    final path = switch (event) {
      JellyfinPlaybackEvent.start => '/Sessions/Playing',
      JellyfinPlaybackEvent.progress => '/Sessions/Playing/Progress',
      JellyfinPlaybackEvent.stopped => '/Sessions/Playing/Stopped',
    };
    final response = await _request(
      () => _client.post(
        address.endpoint(path),
        headers: {
          ..._authenticatedHeaders(session),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'ItemId': itemId,
          'PositionTicks': position.inMicroseconds * 10,
          'IsPaused': paused,
          'IsMuted': volume <= 0,
          'VolumeLevel': (volume.clamp(0, 1) * 100).round(),
          'PlayMethod': 'DirectPlay',
          'CanSeek': true,
        }),
      ),
    );
    _requireSuccess(response, operation: 'report playback to Jellyfin');
  }

  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) async {
    final response = await _request(
      () => _client.get(
        address.endpoint('/System/Info/Public'),
        headers: const {'Accept': 'application/json'},
      ),
    );
    _requireSuccess(response, operation: 'contact the Jellyfin server');
    final json = _decodeObject(response.body);
    return JellyfinServerInfo(
      id: _requiredString(json, 'Id'),
      name: _requiredString(json, 'ServerName'),
      version: _requiredString(json, 'Version'),
    );
  }

  @override
  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  }) async {
    final trimmedUserName = userName.trim();
    if (trimmedUserName.isEmpty || password.isEmpty) {
      throw const JellyfinConnectionException(
        'Enter both a Jellyfin username and password.',
      );
    }

    final response = await _request(
      () => _client.post(
        address.endpoint('/Users/AuthenticateByName'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': _authorizationHeader(),
        },
        body: jsonEncode({'Username': trimmedUserName, 'Pw': password}),
      ),
    );
    _requireSuccess(response, operation: 'sign in to Jellyfin');
    final json = _decodeObject(response.body);
    final user = json['User'];
    if (user is! Map<String, dynamic>) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete authentication response.',
      );
    }
    return JellyfinSession(
      accessToken: _requiredString(json, 'AccessToken'),
      userId: _requiredString(user, 'Id'),
      userName: _requiredString(user, 'Name'),
    );
  }

  @override
  Future<List<AlbumSummary>> getRecentlyAddedAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    int limit = 10,
  }) async {
    final page = await getAlbums(
      address: address,
      session: session,
      sort: AlbumSort.recentlyAdded,
      startIndex: 0,
      limit: limit,
    );
    return page.albums;
  }

  @override
  Future<AlbumPage> getAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required AlbumSort sort,
    required int startIndex,
    required int limit,
  }) async {
    if (startIndex < 0 || limit < 1) {
      throw ArgumentError('Album page bounds are invalid.');
    }
    final (sortBy, sortOrder) = switch (sort) {
      AlbumSort.recentlyAdded => ('DateCreated', 'Descending'),
      AlbumSort.title => ('SortName', 'Ascending'),
      AlbumSort.artist => ('AlbumArtist,SortName', 'Ascending'),
      AlbumSort.releaseYear => ('ProductionYear,SortName', 'Descending'),
    };
    final uri = address
        .endpoint('/Users/${session.userId}/Items')
        .replace(
          queryParameters: {
            'IncludeItemTypes': 'MusicAlbum',
            'Recursive': 'true',
            'SortBy': sortBy,
            'SortOrder': sortOrder,
            'StartIndex': '$startIndex',
            'Limit': '$limit',
            'Fields': 'AlbumArtist,DateCreated,ProductionYear',
            'ImageTypeLimit': '1',
            'EnableImageTypes': 'Primary',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'load recently added albums');
    final json = _decodeObject(response.body);
    final items = json['Items'];
    if (items is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete album list.',
      );
    }

    final albums = <AlbumSummary>[];
    for (final value in items) {
      if (value is! Map<String, dynamic>) {
        continue;
      }
      final id = value['Id'];
      final title = value['Name'];
      if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
        continue;
      }
      final artist = _albumArtist(value);
      final imageTags = value['ImageTags'];
      final imageTag = imageTags is Map ? imageTags['Primary'] : null;
      final artwork = imageTag is String && imageTag.isNotEmpty
          ? await _loadArtwork(address, session, id, imageTag)
          : null;
      albums.add(
        AlbumSummary(
          id: id,
          title: title,
          artist: artist,
          year: value['ProductionYear'] is int
              ? value['ProductionYear'] as int
              : null,
          imageTag: imageTag is String ? imageTag : null,
          artworkBytes: artwork,
        ),
      );
    }
    final total = json['TotalRecordCount'];
    return AlbumPage(
      albums: albums,
      totalCount: total is int ? total : startIndex + albums.length,
    );
  }

  @override
  Future<ArtistPage> getArtists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async {
    final uri = address
        .endpoint('/Artists')
        .replace(
          queryParameters: {
            'UserId': session.userId,
            'Recursive': 'true',
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
            'StartIndex': '$startIndex',
            'Limit': '$limit',
            'ImageTypeLimit': '1',
            'EnableImageTypes': 'Primary',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'load artists from Jellyfin');
    final json = _decodeObject(response.body);
    final values = json['Items'];
    if (values is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete artist list.',
      );
    }
    final artists = <ArtistSummary>[];
    for (final value in values.whereType<Map<String, dynamic>>()) {
      final id = value['Id'];
      final name = value['Name'];
      if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
        continue;
      }
      final imageTag = _primaryImageTag(value);
      artists.add(
        ArtistSummary(
          id: id,
          name: name,
          imageTag: imageTag,
          artworkBytes: imageTag == null
              ? null
              : await _loadArtwork(address, session, id, imageTag),
        ),
      );
    }
    final total = json['TotalRecordCount'];
    return ArtistPage(
      artists: artists,
      totalCount: total is int ? total : startIndex + artists.length,
    );
  }

  @override
  Future<List<AlbumSummary>> getArtistAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String artistId,
  }) async {
    final uri = address
        .endpoint('/Users/${session.userId}/Items')
        .replace(
          queryParameters: {
            'IncludeItemTypes': 'MusicAlbum',
            'Recursive': 'true',
            'AlbumArtistIds': artistId,
            'SortBy': 'ProductionYear,SortName',
            'SortOrder': 'Descending',
            'Fields': 'AlbumArtist,ProductionYear',
            'ImageTypeLimit': '1',
            'EnableImageTypes': 'Primary',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'load albums for an artist');
    final values = _decodeObject(response.body)['Items'];
    if (values is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete artist album list.',
      );
    }
    final albums = <AlbumSummary>[];
    for (final value in values.whereType<Map<String, dynamic>>()) {
      final id = value['Id'];
      final title = value['Name'];
      if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
        continue;
      }
      final imageTag = _primaryImageTag(value);
      albums.add(
        AlbumSummary(
          id: id,
          title: title,
          artist: _albumArtist(value),
          year: value['ProductionYear'] is int
              ? value['ProductionYear'] as int
              : null,
          imageTag: imageTag,
          artworkBytes: imageTag == null
              ? null
              : await _loadArtwork(address, session, id, imageTag),
        ),
      );
    }
    return albums;
  }

  @override
  Future<List<TrackSummary>> getAlbumTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String albumId,
  }) async {
    final uri = address
        .endpoint('/Users/${session.userId}/Items')
        .replace(
          queryParameters: {
            'ParentId': albumId,
            'IncludeItemTypes': 'Audio',
            'Recursive': 'true',
            'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
            'SortOrder': 'Ascending',
            'Fields': 'Artists,RunTimeTicks',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'load album tracks');
    final values = _decodeObject(response.body)['Items'];
    if (values is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete track list.',
      );
    }
    return values
        .whereType<Map<String, dynamic>>()
        .map((value) {
          final ticks = value['RunTimeTicks'];
          return TrackSummary(
            id: _requiredString(value, 'Id'),
            title: _requiredString(value, 'Name'),
            artist: _trackArtist(value),
            duration: Duration(microseconds: ticks is int ? ticks ~/ 10 : 0),
            trackNumber: value['IndexNumber'] is int
                ? value['IndexNumber'] as int
                : null,
            discNumber: value['ParentIndexNumber'] is int
                ? value['ParentIndexNumber'] as int
                : null,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<LibrarySearchResults> searchLibrary({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String query,
    int limit = 24,
  }) async {
    final term = query.trim();
    if (term.isEmpty) {
      return const LibrarySearchResults();
    }
    final uri = address
        .endpoint('/Users/${session.userId}/Items')
        .replace(
          queryParameters: {
            'SearchTerm': term,
            'IncludeItemTypes': 'MusicAlbum,Audio',
            'Recursive': 'true',
            'Limit': '$limit',
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
            'Fields':
                'AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ProductionYear,RunTimeTicks',
            'ImageTypeLimit': '1',
            'EnableImageTypes': 'Primary',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'search the music library');
    final values = _decodeObject(response.body)['Items'];
    if (values is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned incomplete search results.',
      );
    }

    final albums = <AlbumSummary>[];
    final tracks = <TrackSearchResult>[];
    for (final value in values.whereType<Map<String, dynamic>>()) {
      final type = value['Type'];
      final id = value['Id'];
      final title = value['Name'];
      if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
        continue;
      }
      if (type == 'MusicAlbum') {
        final imageTag = _primaryImageTag(value);
        albums.add(
          AlbumSummary(
            id: id,
            title: title,
            artist: _albumArtist(value),
            year: value['ProductionYear'] is int
                ? value['ProductionYear'] as int
                : null,
            imageTag: imageTag,
            artworkBytes: imageTag == null
                ? null
                : await _loadArtwork(address, session, id, imageTag),
          ),
        );
      } else if (type == 'Audio') {
        final ticks = value['RunTimeTicks'];
        final albumId = value['AlbumId'];
        final albumImageTag = value['AlbumPrimaryImageTag'];
        tracks.add(
          TrackSearchResult(
            track: TrackSummary(
              id: id,
              title: title,
              artist: _trackArtist(value),
              duration: Duration(microseconds: ticks is int ? ticks ~/ 10 : 0),
              trackNumber: value['IndexNumber'] is int
                  ? value['IndexNumber'] as int
                  : null,
              discNumber: value['ParentIndexNumber'] is int
                  ? value['ParentIndexNumber'] as int
                  : null,
            ),
            artworkBytes:
                albumId is String &&
                    albumId.isNotEmpty &&
                    albumImageTag is String &&
                    albumImageTag.isNotEmpty
                ? await _loadArtwork(address, session, albumId, albumImageTag)
                : null,
          ),
        );
      }
    }
    return LibrarySearchResults(albums: albums, tracks: tracks);
  }

  @override
  Future<TrackLyrics?> getLyrics({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String trackId,
  }) async {
    if (trackId.isEmpty || trackId.contains('/')) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an invalid track identifier.',
      );
    }
    final response = await _request(
      () => _client.get(
        address.endpoint('/Audio/$trackId/Lyrics'),
        headers: _authenticatedHeaders(session),
      ),
    );
    if (response.statusCode == 404) {
      return null;
    }
    _requireSuccess(response, operation: 'load lyrics from Jellyfin');
    final json = _decodeObject(response.body);
    final metadata = json['Metadata'];
    final values = json['Lyrics'];
    if (values is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned incomplete lyrics.',
      );
    }
    final lines = <LyricLine>[];
    for (final value in values.whereType<Map<String, dynamic>>()) {
      final text = value['Text'];
      if (text is! String) {
        continue;
      }
      final start = value['Start'];
      lines.add(
        LyricLine(
          text: text,
          start: start is int ? Duration(microseconds: start ~/ 10) : null,
        ),
      );
    }
    return TrackLyrics(
      lines: List.unmodifiable(lines),
      isSynchronized:
          metadata is Map<String, dynamic> && metadata['IsSynced'] == true,
    );
  }

  String? _primaryImageTag(Map<String, dynamic> item) {
    final tags = item['ImageTags'];
    final tag = tags is Map ? tags['Primary'] : null;
    return tag is String && tag.isNotEmpty ? tag : null;
  }

  @override
  Future<void> validateSession({
    required JellyfinServerAddress address,
    required JellyfinSession session,
  }) async {
    final response = await _request(
      () => _client.get(
        address.endpoint('/Users/Me'),
        headers: _authenticatedHeaders(session),
      ),
    );
    _requireSuccess(response, operation: 'restore the Jellyfin session');
    final json = _decodeObject(response.body);
    if (_requiredString(json, 'Id') != session.userId) {
      throw const JellyfinConnectionException(
        'The saved Jellyfin session belongs to a different user.',
      );
    }
  }

  Map<String, String> _authenticatedHeaders(JellyfinSession session) => {
    'Accept': 'application/json',
    'Authorization': _authorizationHeader(token: session.accessToken),
  };

  String _albumArtist(Map<String, dynamic> item) {
    final albumArtist = item['AlbumArtist'];
    if (albumArtist is String && albumArtist.isNotEmpty) {
      return albumArtist;
    }
    final artists = item['AlbumArtists'];
    if (artists is List && artists.isNotEmpty) {
      final first = artists.first;
      if (first is Map && first['Name'] is String) {
        return first['Name'] as String;
      }
    }
    return 'Unknown artist';
  }

  String _trackArtist(Map<String, dynamic> item) {
    final artists = item['Artists'];
    if (artists is List) {
      final names = artists.whereType<String>().where(
        (name) => name.isNotEmpty,
      );
      if (names.isNotEmpty) {
        return names.join(', ');
      }
    }
    return 'Unknown artist';
  }

  Future<Uint8List?> _loadArtwork(
    JellyfinServerAddress address,
    JellyfinSession session,
    String itemId,
    String imageTag,
  ) async {
    final key = ArtworkCacheKey(
      server: address.toString(),
      itemId: itemId,
      imageTag: imageTag,
      maxWidth: 600,
    );
    Uint8List? cached;
    try {
      cached = await artworkCache.read(key);
    } catch (_) {
      // A cache failure must never prevent authenticated artwork loading.
    }
    if (cached != null) {
      return cached;
    }
    try {
      final uri = address
          .endpoint('/Items/$itemId/Images/Primary')
          .replace(queryParameters: const {'maxWidth': '600', 'quality': '90'});
      final response = await _request(
        () => _client.get(uri, headers: _authenticatedHeaders(session)),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          await artworkCache.write(key, response.bodyBytes);
        } catch (_) {
          // The network result remains usable when local persistence fails.
        }
        return response.bodyBytes;
      }
    } on JellyfinConnectionException {
      // Missing artwork must not prevent the album list from loading.
    }
    return null;
  }

  String _authorizationHeader({String? token}) {
    final values = [
      'Client="${_quote(_identity.clientName)}"',
      'Device="${_quote(_identity.deviceName)}"',
      'DeviceId="${_quote(_identity.deviceId)}"',
      'Version="${_quote(_identity.version)}"',
      if (token != null) 'Token="${_quote(token)}"',
    ];
    return 'MediaBrowser ${values.join(', ')}';
  }

  Future<http.Response> _request(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request().timeout(requestTimeout);
    } on TimeoutException {
      throw const JellyfinConnectionException(
        'The Jellyfin server did not respond in time.',
      );
    } on http.ClientException {
      throw const JellyfinConnectionException(
        'Could not reach the Jellyfin server.',
      );
    }
  }

  void _requireSuccess(http.Response response, {required String operation}) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JellyfinConnectionException(
        'Could not $operation (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
  }

  Map<String, dynamic> _decodeObject(String body) {
    try {
      final value = jsonDecode(body);
      if (value is Map<String, dynamic>) {
        return value;
      }
    } on FormatException {
      // The safe error below intentionally excludes the private response body.
    }
    throw const JellyfinConnectionException(
      'Jellyfin returned a response that gaze could not understand.',
    );
  }

  String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw const JellyfinConnectionException(
      'Jellyfin returned an incomplete response.',
    );
  }

  static void _validateIdentity(JellyfinClientIdentity identity) {
    for (final value in [
      identity.clientName,
      identity.deviceName,
      identity.deviceId,
      identity.version,
    ]) {
      if (value.isEmpty || value.contains('\r') || value.contains('\n')) {
        throw ArgumentError(
          'Jellyfin client identity values must be non-empty.',
        );
      }
    }
  }

  String _quote(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  @override
  void close() => _client.close();
}
