import 'dart:typed_data';
import 'package:gaze/library/playlist_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/jellyfin/jellyfin_credential_store.dart';
import 'package:gaze/library/album_summary.dart';
import 'package:gaze/library/artist_summary.dart';
import 'package:gaze/library/library_search_results.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/library/track_lyrics.dart';
import 'package:gaze/library/track_summary.dart';
import 'package:gaze/storage/library_metadata_cache.dart';
import 'package:gaze/storage/sqlite_library_metadata_cache.dart';

void main() {
  test('connects and saves only the returned access token', () async {
    final credentials = MemoryCredentialStore();
    final api = RecordingJellyfinApi();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (deviceId) {
        expect(deviceId, 'stable-device-id');
        return api;
      },
    );

    await controller.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'temporary-password',
    );

    expect(controller.state.isConnected, isTrue);
    expect(controller.state.serverInfo?.name, 'Music Server');
    expect(credentials.accessToken, 'test-access-token');
    expect(api.receivedPassword, 'temporary-password');
    await controller.dispose();
  });

  test('disconnect removes the token', () async {
    final credentials = MemoryCredentialStore();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (_) => RecordingJellyfinApi(),
    );
    await controller.connect(
      serverAddress: 'https://music.example',
      userName: 'listener',
      password: 'temporary-password',
    );

    await controller.disconnect();

    expect(controller.state.isConnected, isFalse);
    expect(credentials.accessToken, isNull);
    await controller.dispose();
  });

  test('restores and validates a saved session', () async {
    final credentials = MemoryCredentialStore()
      ..connection = const SavedJellyfinConnection(
        serverAddress: 'http://music.local:8096',
        accessToken: 'saved-token',
        userId: 'test-user-id',
        userName: 'listener',
      );
    final api = RecordingJellyfinApi();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (_) => api,
    );

    await controller.restore();

    expect(controller.state.isConnected, isTrue);
    expect(controller.state.session?.accessToken, 'saved-token');
    expect(api.validatedSession, isTrue);
    await controller.dispose();
  });

  test('shows safe connection errors without saving a token', () async {
    final credentials = MemoryCredentialStore();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (_) => FailingJellyfinApi(),
    );

    await controller.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'temporary-password',
    );

    expect(controller.state.isConnected, isFalse);
    expect(controller.state.errorMessage, 'Could not reach the test server.');
    expect(credentials.accessToken, isNull);
    await controller.dispose();
  });

  test('restores cached library access when the server is offline', () async {
    final credentials = MemoryCredentialStore()
      ..connection = const SavedJellyfinConnection(
        serverAddress: 'http://music.local:8096',
        accessToken: 'saved-token',
        userId: 'test-user-id',
        userName: 'listener',
        serverId: 'test-server-id',
        serverName: 'Music Server',
        serverVersion: '10.11.0',
      );
    final metadata = SqliteLibraryMetadataCache.inMemory();
    await metadata.writeAlbumPage(
      const AlbumPageCacheKey(
        serverId: 'test-server-id',
        userId: 'test-user-id',
        sort: AlbumSort.title,
        startIndex: 0,
        limit: 24,
      ),
      const AlbumPage(
        albums: [
          AlbumSummary(id: 'album', title: 'Saved Album', artist: 'Artist'),
        ],
        totalCount: 1,
      ),
    );
    await metadata.writeSongs(
      const SongLibraryCacheKey(
        serverId: 'test-server-id',
        userId: 'test-user-id',
      ),
      const SongPage(
        songs: [
          SongSummary(
            track: TrackSummary(
              id: 'saved-song',
              title: 'Saved Song',
              artist: 'Artist',
              duration: Duration(minutes: 3),
            ),
            album: 'Saved Album',
          ),
        ],
        totalCount: 1,
      ),
    );
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      metadataCache: metadata,
      apiFactory: (_) => FailingJellyfinApi(),
    );

    await controller.restore();
    final page = await controller.loadAlbums(
      sort: AlbumSort.title,
      startIndex: 0,
    );
    final songs = await controller.loadCachedSongs();

    expect(controller.state.status, JellyfinConnectionStatus.offline);
    expect(controller.state.canBrowseLibrary, isTrue);
    expect(credentials.accessToken, 'saved-token');
    expect(page.albums.single.title, 'Saved Album');
    expect(page.isStale, isTrue);
    expect(songs!.songs.single.track.title, 'Saved Song');
    await controller.dispose();
    await metadata.close();
  });

  test('removes a saved session after an authentication rejection', () async {
    final credentials = MemoryCredentialStore()
      ..connection = const SavedJellyfinConnection(
        serverAddress: 'http://music.local:8096',
        accessToken: 'expired-token',
        userId: 'test-user-id',
        userName: 'listener',
        serverId: 'test-server-id',
      );
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (_) => FailingJellyfinApi(
        error: const JellyfinConnectionException(
          'Session expired.',
          statusCode: 401,
        ),
      ),
    );

    await controller.restore();

    expect(controller.state.canBrowseLibrary, isFalse);
    expect(credentials.accessToken, isNull);
    await controller.dispose();
  });
}

class MemoryCredentialStore implements JellyfinCredentialStore {
  SavedJellyfinConnection? connection;
  SavedJellyfinProfile? profile;

  String? get accessToken => connection?.accessToken;

  @override
  Future<void> deleteConnection() async => connection = null;

  @override
  Future<String> getOrCreateDeviceId() async => 'stable-device-id';

  @override
  Future<SavedJellyfinConnection?> readConnection() async => connection;

  @override
  Future<SavedJellyfinProfile?> readProfile() async => profile;

  @override
  Future<void> writeConnection(SavedJellyfinConnection value) async =>
      connection = value;

  @override
  Future<void> writeProfile(SavedJellyfinProfile value) async =>
      profile = value;
}

class RecordingJellyfinApi implements JellyfinApi {
  String? receivedPassword;
  bool validatedSession = false;

  @override
  Future<void> reportPlayback({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required JellyfinPlaybackEvent event,
    required String itemId,
    required Duration position,
    required double volume,
    required bool paused,
  }) async {}

  @override
  JellyfinAudioStreamSource createDirectPlaySource({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
  }) => JellyfinAudioStreamSource(
    uri: address.endpoint('/Audio/$itemId/stream'),
    headers: const {'Authorization': 'test-auth-header'},
  );

  @override
  Future<AlbumPage> getAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required AlbumSort sort,
    required int startIndex,
    required int limit,
  }) async => const AlbumPage(albums: [], totalCount: 0);

  @override
  Future<ArtistPage> getArtists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => const ArtistPage(artists: [], totalCount: 0);

  @override
  Future<List<AlbumSummary>> getArtistAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String artistId,
  }) async => const [];

  @override
  Future<List<TrackSummary>> getAlbumTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String albumId,
  }) async => const [];

  @override
  Future<SongPage> getSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => const SongPage(songs: [], totalCount: 0);

  @override
  Future<TrackLyrics?> getLyrics({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String trackId,
  }) async => null;

  @override
  Future<Uint8List?> getArtwork({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
    required String? imageTag,
  }) async => null;
  @override
  Future<PlaylistPage> getPlaylists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => const PlaylistPage(playlists: [], totalCount: 0);
  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) async => const SongPage(songs: [], totalCount: 0);

  @override
  Future<PlaylistSummary> createPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String name,
    List<String> itemIds = const [],
  }) async => PlaylistSummary(
    id: 'new-playlist',
    title: name,
    trackCount: itemIds.length,
  );
  @override
  Future<bool> canEditPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => true;
  @override
  Future<PlaylistSummary> getPlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => PlaylistSummary(id: playlistId, title: 'Playlist');
  @override
  Future<PlaylistSummary> updatePlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
    required String description,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) async =>
      PlaylistSummary(id: playlistId, title: name, description: description);
  @override
  Future<void> renamePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
  }) async {}
  @override
  Future<void> addPlaylistSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required List<String> itemIds,
  }) async {}
  @override
  Future<void> removePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
  }) async {}
  @override
  Future<void> movePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
    required int newIndex,
  }) async {}
  @override
  Future<void> deletePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async {}

  @override
  Future<LibrarySearchResults> searchLibrary({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String query,
    int limit = 24,
  }) async => const LibrarySearchResults();

  @override
  Future<List<AlbumSummary>> getRecentlyAddedAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    int limit = 10,
  }) async => const [];

  @override
  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  }) async {
    receivedPassword = password;
    return JellyfinSession(
      accessToken: 'test-access-token',
      userId: 'test-user-id',
      userName: userName,
    );
  }

  @override
  void close() {}

  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) async {
    return const JellyfinServerInfo(
      id: 'test-server-id',
      name: 'Music Server',
      version: '10.11.0',
    );
  }

  @override
  Future<void> validateSession({
    required JellyfinServerAddress address,
    required JellyfinSession session,
  }) async => validatedSession = true;
}

class FailingJellyfinApi implements JellyfinApi {
  FailingJellyfinApi({
    this.error = const JellyfinConnectionException(
      'Could not reach the test server.',
    ),
  });

  final JellyfinConnectionException error;
  @override
  Future<void> reportPlayback({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required JellyfinPlaybackEvent event,
    required String itemId,
    required Duration position,
    required double volume,
    required bool paused,
  }) async {}

  @override
  JellyfinAudioStreamSource createDirectPlaySource({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
  }) => JellyfinAudioStreamSource(
    uri: address.endpoint('/Audio/$itemId/stream'),
    headers: const {},
  );

  @override
  Future<AlbumPage> getAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required AlbumSort sort,
    required int startIndex,
    required int limit,
  }) async => const AlbumPage(albums: [], totalCount: 0);

  @override
  Future<ArtistPage> getArtists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => throw error;

  @override
  Future<List<AlbumSummary>> getArtistAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String artistId,
  }) async => throw error;

  @override
  Future<List<TrackSummary>> getAlbumTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String albumId,
  }) async => const [];

  @override
  Future<SongPage> getSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => const SongPage(songs: [], totalCount: 0);

  @override
  Future<TrackLyrics?> getLyrics({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String trackId,
  }) async => throw error;

  @override
  Future<Uint8List?> getArtwork({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
    required String? imageTag,
  }) async => null;
  @override
  Future<PlaylistPage> getPlaylists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => const PlaylistPage(playlists: [], totalCount: 0);
  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) async => const SongPage(songs: [], totalCount: 0);

  @override
  Future<PlaylistSummary> createPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String name,
    List<String> itemIds = const [],
  }) async => PlaylistSummary(
    id: 'new-playlist',
    title: name,
    trackCount: itemIds.length,
  );
  @override
  Future<bool> canEditPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => true;
  @override
  Future<PlaylistSummary> getPlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => PlaylistSummary(id: playlistId, title: 'Playlist');
  @override
  Future<PlaylistSummary> updatePlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
    required String description,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) async =>
      PlaylistSummary(id: playlistId, title: name, description: description);
  @override
  Future<void> renamePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
  }) async {}
  @override
  Future<void> addPlaylistSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required List<String> itemIds,
  }) async {}
  @override
  Future<void> removePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
  }) async {}
  @override
  Future<void> movePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
    required int newIndex,
  }) async {}
  @override
  Future<void> deletePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async {}

  @override
  Future<LibrarySearchResults> searchLibrary({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String query,
    int limit = 24,
  }) async => throw error;

  @override
  Future<List<AlbumSummary>> getRecentlyAddedAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    int limit = 10,
  }) async => const [];

  @override
  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  }) {
    throw UnimplementedError();
  }

  @override
  void close() {}

  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) {
    throw error;
  }

  @override
  Future<void> validateSession({
    required JellyfinServerAddress address,
    required JellyfinSession session,
  }) async {}
}
