import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../library/playlist_summary.dart';
import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/library_search_results.dart';
import '../library/song_summary.dart';
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
  final Map<String, Future<Uint8List?>> _artworkRequests = {};
  final Queue<Completer<void>> _artworkWaiters = Queue();
  int _activeArtwork = 0;

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
      albums.add(
        AlbumSummary(
          id: id,
          title: title,
          artist: artist,
          year: value['ProductionYear'] is int
              ? value['ProductionYear'] as int
              : null,
          imageTag: imageTag is String ? imageTag : null,
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
      artists.add(ArtistSummary(id: id, name: name, imageTag: imageTag));
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
  Future<SongPage> getSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async {
    final uri = address
        .endpoint('/Users/${session.userId}/Items')
        .replace(
          queryParameters: {
            'IncludeItemTypes': 'Audio',
            'Recursive': 'true',
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
            'StartIndex': '$startIndex',
            'Limit': '$limit',
            'Fields': 'Artists,Album,AlbumId,AlbumPrimaryImageTag,RunTimeTicks',
            'ImageTypeLimit': '1',
            'EnableImageTypes': 'Primary',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'load songs');
    final body = _decodeObject(response.body);
    final values = body['Items'];
    if (values is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete song list.',
      );
    }
    return _songPage(body, startIndex);
  }

  SongPage _songPage(Map<String, dynamic> body, int startIndex) {
    final values = body['Items'];
    if (values is! List) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete song list.',
      );
    }
    final songs = <SongSummary>[];
    for (final value in values.whereType<Map<String, dynamic>>()) {
      if (value['Type'] != null && value['Type'] != 'Audio') continue;
      final id = value['Id'];
      final title = value['Name'];
      if (id is! String || id.isEmpty || title is! String || title.isEmpty)
        continue;
      final ticks = value['RunTimeTicks'];
      final albumId = value['AlbumId'];
      final imageTag = value['AlbumPrimaryImageTag'];
      songs.add(
        SongSummary(
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
          album:
              value['Album'] is String && (value['Album'] as String).isNotEmpty
              ? value['Album'] as String
              : 'Unknown album',
          entryId: value['PlaylistItemId'] is String
              ? value['PlaylistItemId'] as String
              : null,
          albumId: albumId is String && albumId.isNotEmpty ? albumId : null,
          imageTag: imageTag is String && imageTag.isNotEmpty ? imageTag : null,
        ),
      );
    }
    return SongPage(
      songs: songs,
      totalCount: body['TotalRecordCount'] is int
          ? body['TotalRecordCount'] as int
          : startIndex + values.length,
      nextStartIndex: startIndex + values.length,
    );
  }

  @override
  Future<Uint8List?> getArtwork({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
    required String? imageTag,
  }) => _loadArtwork(address, session, itemId, imageTag);

  @override
  Future<PlaylistPage> getPlaylists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async {
    final uri = address
        .endpoint('/Users/${session.userId}/Items')
        .replace(
          queryParameters: {
            'IncludeItemTypes': 'Playlist',
            'Recursive': 'true',
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
            'StartIndex': '$startIndex',
            'Limit': '$limit',
            'Fields': 'ChildCount,Overview',
            'ImageTypeLimit': '1',
            'EnableImageTypes': 'Primary',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'load playlists');
    final body = _decodeObject(response.body);
    final values = body['Items'];
    if (values is! List)
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete playlist list.',
      );
    final playlists = <PlaylistSummary>[];
    for (final value in values.whereType<Map<String, dynamic>>()) {
      final id = value['Id'];
      final title = value['Name'];
      if (id is! String || id.isEmpty || title is! String || title.isEmpty)
        continue;
      if (value['MediaType'] != null && value['MediaType'] != 'Audio') continue;
      final tags = value['ImageTags'];
      playlists.add(
        PlaylistSummary(
          id: id,
          title: title,
          trackCount: value['ChildCount'] is int
              ? value['ChildCount'] as int
              : null,
          imageTag: tags is Map && tags['Primary'] is String
              ? tags['Primary'] as String
              : null,
          description: value['Overview'] is String
              ? value['Overview'] as String
              : '',
        ),
      );
    }
    return PlaylistPage(
      playlists: playlists,
      totalCount: body['TotalRecordCount'] is int
          ? body['TotalRecordCount'] as int
          : startIndex + values.length,
      nextStartIndex: startIndex + values.length,
    );
  }

  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) async {
    final uri = address
        .endpoint('/Playlists/$playlistId/Items')
        .replace(
          queryParameters: {
            'UserId': session.userId,
            'StartIndex': '$startIndex',
            'Limit': '$limit',
            'Fields': 'Artists,Album,AlbumId,AlbumPrimaryImageTag,RunTimeTicks',
            'ImageTypeLimit': '1',
            'EnableImageTypes': 'Primary',
          },
        );
    final response = await _request(
      () => _client.get(uri, headers: _authenticatedHeaders(session)),
    );
    _requireSuccess(response, operation: 'load playlist tracks');
    return _songPage(_decodeObject(response.body), startIndex);
  }

  String _playlistName(String value) {
    final name = value.trim();
    if (name.isEmpty || name.length > 140)
      throw const JellyfinConnectionException(
        'Give your playlist a name of 1 to 140 characters.',
      );
    return name;
  }

  void _playlistId(String value) {
    if (value.isEmpty || !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(value))
      throw const JellyfinConnectionException(
        'The playlist identifier was invalid. Refresh and try again.',
      );
  }

  Future<void> _playlistWrite(
    Future<http.Response> Function() action,
    String operation,
  ) async {
    http.Response response;
    try {
      response = await _request(action);
    } on JellyfinConnectionException catch (error) {
      if (error.statusCode == null)
        throw const JellyfinConnectionException(
          'Could not confirm the playlist change. Refresh your playlists before trying again.',
        );
      rethrow;
    }
    if (response.statusCode == 403)
      throw const JellyfinConnectionException(
        'Your account does not have permission to change this playlist.',
        statusCode: 403,
      );
    _requireSuccess(response, operation: operation);
  }

  @override
  Future<PlaylistSummary> createPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String name,
    List<String> itemIds = const [],
  }) async {
    final title = _playlistName(name);
    for (final id in itemIds) {
      _playlistId(id);
    }
    final response = await _request(
      () => _client.post(
        address.endpoint('/Playlists'),
        headers: {
          ..._authenticatedHeaders(session),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'Name': title,
          'UserId': session.userId,
          'MediaType': 'Audio',
          'Ids': itemIds,
          'IsPublic': false,
          'Users': <Object>[],
        }),
      ),
    );
    if (response.statusCode == 403)
      throw const JellyfinConnectionException(
        'Your account does not have permission to create playlists.',
        statusCode: 403,
      );
    _requireSuccess(response, operation: 'create the playlist');
    final id = _requiredString(_decodeObject(response.body), 'Id');
    int? savedCount;
    try {
      savedCount = (await getPlaylistTracks(
        address: address,
        session: session,
        playlistId: id,
        startIndex: 0,
        limit: 1,
      )).totalCount;
    } on JellyfinConnectionException {
      /* Creation succeeded; a refresh can resolve the count later. */
    }
    return PlaylistSummary(id: id, title: title, trackCount: savedCount);
  }

  @override
  Future<bool> canEditPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async {
    _playlistId(playlistId);
    final response = await _request(
      () => _client.get(
        address.endpoint('/Playlists/$playlistId/Users/${session.userId}'),
        headers: _authenticatedHeaders(session),
      ),
    );
    if (response.statusCode == 403 || response.statusCode == 404) return false;
    _requireSuccess(response, operation: 'check playlist permissions');
    if (response.body.trim().isEmpty || response.body.trim() == 'null')
      return false;
    return _decodeObject(response.body)['CanEdit'] == true;
  }

  @override
  Future<void> renamePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
  }) async {
    _playlistId(playlistId);
    final title = _playlistName(name);
    await _playlistWrite(
      () => _client.post(
        address.endpoint('/Playlists/$playlistId'),
        headers: {
          ..._authenticatedHeaders(session),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'Name': title}),
      ),
      'rename the playlist',
    );
  }

  PlaylistSummary _playlistSummary(Map<String, dynamic> item) {
    final tags = item['ImageTags'];
    return PlaylistSummary(
      id: _requiredString(item, 'Id'),
      title: _requiredString(item, 'Name'),
      description: item['Overview'] is String ? item['Overview'] as String : '',
      trackCount: item['ChildCount'] is int ? item['ChildCount'] as int : null,
      imageTag: tags is Map && tags['Primary'] is String
          ? tags['Primary'] as String
          : null,
    );
  }

  Future<Map<String, dynamic>> _playlistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async {
    _playlistId(playlistId);
    // This item-detail endpoint returns the complete DTO, including Settings,
    // ProviderIds, tags, and dates. List summaries are unsafe update payloads.
    final response = await _request(
      () => _client.get(
        address.endpoint('/Users/${session.userId}/Items/$playlistId'),
        headers: _authenticatedHeaders(session),
      ),
    );
    _requireSuccess(response, operation: 'load playlist details');
    final item = _decodeObject(response.body);
    if (item['Type'] != 'Playlist' || item['Id'] != playlistId) {
      throw const JellyfinConnectionException(
        'Only playlists can be edited here. Refresh and try again.',
      );
    }
    return item;
  }

  @override
  Future<PlaylistSummary> getPlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => _playlistSummary(
    await _playlistDetails(
      address: address,
      session: session,
      playlistId: playlistId,
    ),
  );

  void _validatePlaylistImage(Uint8List? bytes, String? mimeType) {
    if (bytes == null && mimeType == null) return;
    if (bytes == null || bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
      throw const JellyfinConnectionException(
        'Choose a cover image smaller than 10 MB.',
      );
    }
    bool startsWith(List<int> signature, [int offset = 0]) =>
        bytes.length >= offset + signature.length &&
        signature.asMap().entries.every(
          (entry) => bytes[offset + entry.key] == entry.value,
        );
    final valid = switch (mimeType) {
      'image/jpeg' => startsWith([0xff, 0xd8, 0xff]),
      'image/png' => startsWith([137, 80, 78, 71, 13, 10, 26, 10]),
      'image/webp' =>
        startsWith([82, 73, 70, 70]) && startsWith([87, 69, 66, 80], 8),
      _ => false,
    };
    if (!valid) {
      throw const JellyfinConnectionException(
        'Choose a valid JPEG, PNG, or WebP cover image.',
      );
    }
  }

  @override
  Future<PlaylistSummary> updatePlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
    required String description,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) async {
    _playlistId(playlistId);
    final title = _playlistName(name);
    final overview = description.trim();
    if (overview.length > 2000) {
      throw const JellyfinConnectionException(
        'Keep the playlist description under 2,001 characters.',
      );
    }
    _validatePlaylistImage(imageBytes, imageMimeType);
    if (!await canEditPlaylist(
      address: address,
      session: session,
      playlistId: playlistId,
    )) {
      throw const JellyfinConnectionException(
        'Your account does not have permission to change this playlist.',
        statusCode: 403,
      );
    }
    final existing = await _playlistDetails(
      address: address,
      session: session,
      playlistId: playlistId,
    );
    final previous = _playlistSummary(existing);
    final descriptionChanged = previous.description != overview;
    final nameChanged = previous.title != title;
    var textSaved = false;
    var imageSaved = false;
    var stage = 'details';
    try {
      if (descriptionChanged) {
        // Jellyfin's item update replaces metadata fields. Preserve its freshly
        // read DTO and change only these two fields. Playlist membership and
        // sharing live on a separate endpoint and are never sent here.
        await _playlistWrite(
          () => _client.post(
            address.endpoint('/Items/$playlistId'),
            headers: {
              ..._authenticatedHeaders(session),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              ...existing,
              'Name': title,
              'Overview': overview,
            }),
          ),
          'save playlist details',
        );
        textSaved = true;
      } else if (nameChanged) {
        // Name-only changes also work for playlist editors without elevated
        // server metadata permissions.
        await renamePlaylist(
          address: address,
          session: session,
          playlistId: playlistId,
          name: title,
        );
        textSaved = true;
      }
      if (imageBytes != null) {
        stage = 'cover';
        await _playlistWrite(
          () => _client.post(
            address.endpoint('/Items/$playlistId/Images/Primary'),
            headers: {
              ..._authenticatedHeaders(session),
              'Content-Type': imageMimeType!,
            },
            // Jellyfin expects base64 text even with an image Content-Type.
            body: base64Encode(imageBytes),
          ),
          'save the playlist cover',
        );
        imageSaved = true;
      }
      stage = 'refresh';
      return await getPlaylistDetails(
        address: address,
        session: session,
        playlistId: playlistId,
      );
    } on JellyfinConnectionException catch (error) {
      PlaylistSummary? confirmed;
      try {
        confirmed = await getPlaylistDetails(
          address: address,
          session: session,
          playlistId: playlistId,
        );
      } on JellyfinConnectionException {
        // Preserve the draft; never claim unconfirmed updates or roll back
        // another device's more recent playlist changes.
      }
      final String message;
      if (stage == 'refresh' && (textSaved || imageSaved)) {
        message =
            'Your changes were saved, but gaze could not refresh the '
            'playlist. Refresh before making another change.';
      } else if (stage == 'cover') {
        final prefix = textSaved ? 'The playlist details were saved. ' : '';
        message = error.statusCode == 403
            ? '${prefix}Jellyfin requires permission to change cover images. '
                  'Your selected image has not been saved.'
            : '$prefix${error.statusCode == null ? 'Could not confirm the cover change' : 'The cover could not be saved'}. '
                  'Refresh before trying the image again.';
      } else if (error.statusCode == 403 && descriptionChanged) {
        message =
            'Jellyfin requires permission to edit playlist descriptions. '
            'Your changes have not been saved.';
      } else {
        message = error.message;
      }
      throw JellyfinPlaylistUpdateException(
        message,
        statusCode: error.statusCode,
        savedPlaylist: confirmed,
      );
    }
  }

  @override
  Future<void> addPlaylistSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required List<String> itemIds,
  }) async {
    _playlistId(playlistId);
    if (itemIds.isEmpty) return;
    for (final id in itemIds) {
      _playlistId(id);
    }
    await _playlistWrite(
      () => _client.post(
        address
            .endpoint('/Playlists/$playlistId/Items')
            .replace(
              queryParameters: {
                'UserId': session.userId,
                'Ids': itemIds.join(','),
              },
            ),
        headers: _authenticatedHeaders(session),
      ),
      'add songs to the playlist',
    );
  }

  @override
  Future<void> removePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
  }) async {
    _playlistId(playlistId);
    _playlistId(entryId);
    await _playlistWrite(
      () => _client.delete(
        address
            .endpoint('/Playlists/$playlistId/Items')
            .replace(queryParameters: {'EntryIds': entryId}),
        headers: _authenticatedHeaders(session),
      ),
      'remove the song from the playlist',
    );
  }

  @override
  Future<void> movePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
    required int newIndex,
  }) async {
    _playlistId(playlistId);
    _playlistId(entryId);
    if (newIndex < 0)
      throw const JellyfinConnectionException('The song position was invalid.');
    await _playlistWrite(
      () => _client.post(
        address.endpoint(
          '/Playlists/$playlistId/Items/$entryId/Move/$newIndex',
        ),
        headers: _authenticatedHeaders(session),
      ),
      'reorder the playlist',
    );
  }

  @override
  Future<void> deletePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async {
    _playlistId(playlistId);
    final item = await _request(
      () => _client.get(
        address.endpoint('/Users/${session.userId}/Items/$playlistId'),
        headers: _authenticatedHeaders(session),
      ),
    );
    _requireSuccess(item, operation: 'check the playlist');
    if (_decodeObject(item.body)['Type'] != 'Playlist')
      throw const JellyfinConnectionException(
        'Only playlist objects can be deleted here. Your music files are kept.',
      );
    await _playlistWrite(
      () => _client.delete(
        address.endpoint('/Items/$playlistId'),
        headers: _authenticatedHeaders(session),
      ),
      'delete the playlist',
    );
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
            albumId: albumId is String ? albumId : null,
            imageTag: albumImageTag is String ? albumImageTag : null,
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
      final names = artists
          .whereType<Map>()
          .map((artist) => artist['Name'])
          .whereType<String>()
          .where((name) => name.isNotEmpty);
      if (names.isNotEmpty) return names.join('; ');
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
        return names.join('; ');
      }
    }
    return 'Unknown artist';
  }

  Future<Uint8List?> _loadArtwork(
    JellyfinServerAddress address,
    JellyfinSession session,
    String itemId,
    String? imageTag,
  ) {
    final key = '${address.toString()}:${session.userId}:$itemId:$imageTag';
    return _artworkRequests.putIfAbsent(
      key,
      () =>
          (imageTag == null
                  ? _resolveArtwork(address, session, itemId)
                  : _fetchArtwork(address, session, itemId, imageTag))
              .whenComplete(() {
                _artworkRequests.remove(key);
              }),
    );
  }

  // Old queue snapshots and cached library pages may not know that a cover
  // exists yet. Resolve its current identity before using the versioned cache.
  Future<Uint8List?> _resolveArtwork(
    JellyfinServerAddress address,
    JellyfinSession session,
    String itemId,
  ) async {
    await _acquireArtworkSlot();
    String? artworkId;
    String? tag;
    try {
      final response = await _request(
        () => _client.get(
          address.endpoint('/Users/${session.userId}/Items/$itemId'),
          headers: _authenticatedHeaders(session),
        ),
      );
      if (response.statusCode != 200) return null;
      final item = jsonDecode(response.body) as Map<String, dynamic>;
      final images = item['ImageTags'];
      if (images is Map && images['Primary'] is String) {
        artworkId = itemId;
        tag = images['Primary'] as String;
      } else if (item['AlbumId'] is String &&
          item['AlbumPrimaryImageTag'] is String) {
        artworkId = item['AlbumId'] as String;
        tag = item['AlbumPrimaryImageTag'] as String;
      }
    } catch (_) {
      return null;
    } finally {
      _releaseArtworkSlot();
    }
    if (artworkId == null || tag == null || tag.isEmpty) return null;
    final bytes = await _loadArtwork(address, session, artworkId, tag);
    if (bytes != null && artworkId != itemId) {
      try {
        await artworkCache.write(
          ArtworkCacheKey(
            server: address.toString(),
            itemId: itemId,
            imageTag: tag,
            maxWidth: 600,
          ),
          bytes,
        );
      } catch (_) {}
    }
    return bytes;
  }

  Future<void> _acquireArtworkSlot() async {
    if (_activeArtwork < 4) {
      _activeArtwork++;
      return;
    }
    final waiter = Completer<void>();
    _artworkWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseArtworkSlot() {
    if (_artworkWaiters.isNotEmpty) {
      _artworkWaiters.removeFirst().complete();
    } else {
      _activeArtwork--;
    }
  }

  Future<Uint8List?> _fetchArtwork(
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
    await _acquireArtworkSlot();
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
    } finally {
      _releaseArtworkSlot();
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
