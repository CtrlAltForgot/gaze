import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../library/album_summary.dart';
import '../library/track_summary.dart';
import 'jellyfin_api.dart';

class HttpJellyfinApi implements JellyfinApi {
  HttpJellyfinApi({
    required http.Client client,
    required JellyfinClientIdentity identity,
    this.requestTimeout = const Duration(seconds: 12),
  }) : _client = client,
       _identity = identity {
    _validateIdentity(identity);
  }

  final http.Client _client;
  final JellyfinClientIdentity _identity;
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
      final hasArtwork =
          value['ImageTags'] is Map &&
          (value['ImageTags'] as Map).containsKey('Primary');
      final artwork = hasArtwork
          ? await _loadArtwork(address, session, id)
          : null;
      albums.add(
        AlbumSummary(
          id: id,
          title: title,
          artist: artist,
          year: value['ProductionYear'] is int
              ? value['ProductionYear'] as int
              : null,
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
  ) async {
    try {
      final uri = address
          .endpoint('/Items/$itemId/Images/Primary')
          .replace(queryParameters: const {'maxWidth': '600', 'quality': '90'});
      final response = await _request(
        () => _client.get(uri, headers: _authenticatedHeaders(session)),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
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
