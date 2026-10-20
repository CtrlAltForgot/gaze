import 'dart:convert';
import '../library/artist_credits.dart';
import '../artists/artist_profile_provider.dart';
import '../lyrics/lyrics_provider.dart';
import '../storage/local_content_cache.dart';
import '../storage/playlist_snapshot.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../library/playlist_summary.dart';

import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/library_search_results.dart';
import '../library/song_summary.dart';
import '../library/track_lyrics.dart';
import '../library/track_summary.dart';
import '../storage/artwork_cache.dart';
import '../storage/library_metadata_cache.dart';
import 'jellyfin_api.dart';
import 'jellyfin_credential_store.dart';

typedef JellyfinApiFactory = JellyfinApi Function(String deviceId);

enum JellyfinConnectionStatus {
  idle,
  connecting,
  restoring,
  connected,
  offline,
  disconnecting,
}

class JellyfinConnectionState {
  const JellyfinConnectionState({
    this.status = JellyfinConnectionStatus.idle,
    this.serverAddress,
    this.serverInfo,
    this.session,
    this.errorMessage,
  });

  final JellyfinConnectionStatus status;
  final JellyfinServerAddress? serverAddress;
  final JellyfinServerInfo? serverInfo;
  final JellyfinSession? session;
  final String? errorMessage;

  bool get isConnected => status == JellyfinConnectionStatus.connected;
  bool get canBrowseLibrary =>
      isConnected ||
      status == JellyfinConnectionStatus.restoring ||
      status == JellyfinConnectionStatus.offline;
}

class JellyfinConnectionController {
  JellyfinConnectionController({
    required JellyfinApiFactory apiFactory,
    required JellyfinCredentialStore credentialStore,
    this.artworkCache = const DisabledArtworkCache(),
    this.metadataCache = const DisabledLibraryMetadataCache(),
    this.contentCache = const DisabledLocalContentCache(),
    this.lyricsProvider,
    this.artistProfileProvider,
  }) : _apiFactory = apiFactory,
       _credentialStore = credentialStore;

  final JellyfinApiFactory _apiFactory;
  final JellyfinCredentialStore _credentialStore;
  final ArtworkCache artworkCache;
  final LibraryMetadataCache metadataCache;
  final LocalContentCache contentCache;
  final LyricsProvider? lyricsProvider;
  final ArtistProfileProvider? artistProfileProvider;
  final StreamController<void> _libraryChanges =
      StreamController<void>.broadcast();
  Stream<void> get libraryChanges => _libraryChanges.stream;
  Future<SongPage>? _artistLibraryRefresh;
  String? _artistLibraryRefreshAccount;
  final StreamController<JellyfinConnectionState> _states =
      StreamController<JellyfinConnectionState>.broadcast();
  JellyfinConnectionState _state = const JellyfinConnectionState();
  JellyfinApi? _api;
  int _connectionRequest = 0;
  final LinkedHashMap<String, Uint8List> _artwork = LinkedHashMap();
  int _artworkBytes = 0;

  String? get accountKey =>
      _state.canBrowseLibrary &&
          _state.serverInfo != null &&
          _state.session != null
      ? '${_state.serverAddress}:${_state.serverInfo!.id}:${_state.session!.userId}'
      : null;

  JellyfinConnectionState get state => _state;

  Stream<JellyfinConnectionState> get states => _states.stream;

  Future<SavedJellyfinProfile?> loadSavedProfile() =>
      _credentialStore.readProfile();

  Future<void> connect({
    required String serverAddress,
    required String userName,
    required String password,
  }) async {
    if (_state.status == JellyfinConnectionStatus.connecting ||
        _state.status == JellyfinConnectionStatus.restoring) {
      return;
    }
    final request = ++_connectionRequest;

    _emit(
      const JellyfinConnectionState(
        status: JellyfinConnectionStatus.connecting,
      ),
    );
    try {
      final address = JellyfinServerAddress.parse(serverAddress);
      final deviceId = await _credentialStore.getOrCreateDeviceId();
      if (request != _connectionRequest) return;
      _api?.close();
      final api = _apiFactory(deviceId);
      _api = api;
      final serverInfo = await api.getPublicServerInfo(address);
      final session = await api.authenticate(
        address: address,
        userName: userName,
        password: password,
      );
      if (request != _connectionRequest) return;
      String? persistenceWarning;
      try {
        await _credentialStore.writeConnection(
          SavedJellyfinConnection(
            serverAddress: address.toString(),
            accessToken: session.accessToken,
            userId: session.userId,
            userName: session.userName,
            serverId: serverInfo.id,
            serverName: serverInfo.name,
            serverVersion: serverInfo.version,
          ),
        );
        await _credentialStore.writeProfile(
          SavedJellyfinProfile(
            serverAddress: address.toString(),
            userName: session.userName,
          ),
        );
      } catch (_) {
        persistenceWarning =
            'Connected, but the system credential store could not save this '
            'session. You may need to sign in again after restarting gaze.';
      }
      if (request != _connectionRequest) return;
      _emit(
        JellyfinConnectionState(
          status: JellyfinConnectionStatus.connected,
          serverAddress: address,
          serverInfo: serverInfo,
          session: session,
          errorMessage: persistenceWarning,
        ),
      );
    } on JellyfinConnectionException catch (error) {
      if (request != _connectionRequest) return;
      _emit(JellyfinConnectionState(errorMessage: error.message));
    } catch (_) {
      if (request != _connectionRequest) return;
      _emit(
        const JellyfinConnectionState(
          errorMessage: 'gaze encountered an unexpected connection error.',
        ),
      );
    }
  }

  Future<void> restore() async {
    if (_state.status != JellyfinConnectionStatus.idle) {
      return;
    }
    final request = ++_connectionRequest;
    _emit(
      const JellyfinConnectionState(
        status: JellyfinConnectionStatus.connecting,
      ),
    );
    SavedJellyfinConnection? saved;
    JellyfinServerAddress? address;
    JellyfinSession? session;
    try {
      saved = await _credentialStore.readConnection();
      if (request != _connectionRequest) return;
      if (saved == null) {
        _emit(const JellyfinConnectionState());
        return;
      }
      address = JellyfinServerAddress.parse(saved.serverAddress);
      final deviceId = await _credentialStore.getOrCreateDeviceId();
      if (request != _connectionRequest) return;
      final api = _apiFactory(deviceId);
      _api?.close();
      _api = api;
      session = JellyfinSession(
        accessToken: saved.accessToken,
        userId: saved.userId,
        userName: saved.userName,
      );
      // Saved metadata is usable before the network validates streaming access.
      if (saved.serverId != null) {
        _emit(
          JellyfinConnectionState(
            status: JellyfinConnectionStatus.restoring,
            serverAddress: address,
            serverInfo: JellyfinServerInfo(
              id: saved.serverId!,
              name: saved.serverName ?? 'Saved Jellyfin server',
              version: saved.serverVersion ?? 'unknown',
            ),
            session: session,
          ),
        );
      }
      final results = await Future.wait<Object?>([
        api.getPublicServerInfo(address),
        api.validateSession(address: address, session: session),
      ], eagerError: true);
      if (request != _connectionRequest) return;
      final serverInfo = results.first as JellyfinServerInfo;
      _emit(
        JellyfinConnectionState(
          status: JellyfinConnectionStatus.connected,
          serverAddress: address,
          serverInfo: serverInfo,
          session: session,
        ),
      );
      try {
        await _credentialStore.writeConnection(
          SavedJellyfinConnection(
            serverAddress: address.toString(),
            accessToken: session.accessToken,
            userId: session.userId,
            userName: session.userName,
            serverId: serverInfo.id,
            serverName: serverInfo.name,
            serverVersion: serverInfo.version,
          ),
        );
      } catch (_) {
        // Identity enrichment is optional after a valid session is restored.
      }
    } on JellyfinConnectionException catch (error) {
      if (request != _connectionRequest) return;
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _credentialStore.deleteConnection();
        if (request != _connectionRequest) return;
        _emit(JellyfinConnectionState(errorMessage: error.message));
      } else if (saved?.serverId != null &&
          address != null &&
          session != null) {
        _emit(
          JellyfinConnectionState(
            status: JellyfinConnectionStatus.offline,
            serverAddress: address,
            serverInfo: JellyfinServerInfo(
              id: saved!.serverId!,
              name: saved.serverName ?? 'Saved Jellyfin server',
              version: saved.serverVersion ?? 'unknown',
            ),
            session: session,
            errorMessage:
                'Jellyfin is unavailable. Showing saved library data.',
          ),
        );
      } else {
        _emit(JellyfinConnectionState(errorMessage: error.message));
      }
    } catch (_) {
      if (request != _connectionRequest) return;
      _emit(
        const JellyfinConnectionState(
          errorMessage: 'gaze could not restore the saved Jellyfin session.',
        ),
      );
    }
  }

  Future<void> disconnect() async {
    if (_state.status == JellyfinConnectionStatus.disconnecting) {
      return;
    }
    ++_connectionRequest;
    _emit(
      JellyfinConnectionState(
        status: JellyfinConnectionStatus.disconnecting,
        serverAddress: _state.serverAddress,
        serverInfo: _state.serverInfo,
        session: _state.session,
      ),
    );
    try {
      await _credentialStore.deleteConnection();
      _emit(const JellyfinConnectionState());
    } catch (_) {
      _emit(
        JellyfinConnectionState(
          status: JellyfinConnectionStatus.connected,
          serverAddress: _state.serverAddress,
          serverInfo: _state.serverInfo,
          session: _state.session,
          errorMessage: 'gaze could not remove the saved Jellyfin session.',
        ),
      );
    }
  }

  Future<void> reconnect() async {
    if (_state.status != JellyfinConnectionStatus.offline) {
      return;
    }
    final request = ++_connectionRequest;
    final api = _api;
    final address = _state.serverAddress;
    final session = _state.session;
    if (api == null || address == null || session == null) {
      return;
    }
    try {
      final serverInfo = await api.getPublicServerInfo(address);
      await api.validateSession(address: address, session: session);
      if (request != _connectionRequest) return;
      _emit(
        JellyfinConnectionState(
          status: JellyfinConnectionStatus.connected,
          serverAddress: address,
          serverInfo: serverInfo,
          session: session,
        ),
      );
    } on JellyfinConnectionException catch (error) {
      if (request != _connectionRequest) return;
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _credentialStore.deleteConnection();
        if (request != _connectionRequest) return;
        _emit(JellyfinConnectionState(errorMessage: error.message));
      } else {
        _emit(
          JellyfinConnectionState(
            status: JellyfinConnectionStatus.offline,
            serverAddress: address,
            serverInfo: _state.serverInfo,
            session: session,
            errorMessage:
                'Jellyfin is still unavailable. Showing saved library data.',
          ),
        );
      }
    }
  }

  Future<List<AlbumSummary>> loadRecentlyAddedAlbums({int limit = 10}) async {
    final page = await loadAlbums(
      sort: AlbumSort.recentlyAdded,
      startIndex: 0,
      limit: limit,
    );
    return page.albums;
  }

  Future<AlbumPage> loadAlbums({
    required AlbumSort sort,
    required int startIndex,
    int limit = 24,
  }) => watchAlbums(sort: sort, startIndex: startIndex, limit: limit).last;

  /// Show any saved page immediately, then refresh it without hiding the page.
  Stream<AlbumPage> watchAlbums({
    required AlbumSort sort,
    required int startIndex,
    int limit = 24,
    bool forceRefresh = false,
  }) async* {
    final api = _api;
    final address = _state.serverAddress;
    final session = _state.session;
    final serverId = _state.serverInfo?.id;
    final request = _connectionRequest;
    bool active() =>
        request == _connectionRequest &&
        identical(_api, api) &&
        identical(_state.session, session) &&
        _state.canBrowseLibrary;
    if (!_state.canBrowseLibrary ||
        api == null ||
        address == null ||
        session == null ||
        serverId == null) {
      throw const JellyfinConnectionException(
        'Connect to Jellyfin before browsing albums.',
      );
    }
    final key = AlbumPageCacheKey(
      serverId: serverId,
      userId: session.userId,
      sort: sort,
      startIndex: startIndex,
      limit: limit,
    );
    CachedAlbumPage? cached;
    try {
      cached = await metadataCache.readAlbumPage(key);
    } catch (_) {
      // Local cache failures must not block live browsing.
    }
    if (!active()) return;
    if (cached != null) {
      yield AlbumPage(
        albums: cached.page.albums,
        totalCount: cached.page.totalCount,
        isStale: !_state.isConnected || !cached.isFreshAt(DateTime.now()),
        cachedAt: cached.storedAt,
      );
    }
    if (!active()) return;
    if (!_state.isConnected) {
      if (cached == null &&
          _state.status != JellyfinConnectionStatus.restoring) {
        throw const JellyfinConnectionException(
          'This part of the library has not been saved on this device.',
        );
      }
      return;
    }
    if (!forceRefresh && cached != null && cached.isFreshAt(DateTime.now())) {
      return;
    }
    try {
      final page = await api.getAlbums(
        address: address,
        session: session,
        sort: sort,
        startIndex: startIndex,
        limit: limit,
      );
      if (!active()) return;
      yield page;
      if (!active()) return;
      try {
        await metadataCache.writeAlbumPage(key, page);
      } catch (_) {
        // Keep the response usable even if persistence is unavailable.
      }
    } on JellyfinConnectionException {
      if (cached == null) rethrow;
      if (active()) {
        yield AlbumPage(
          albums: cached.page.albums,
          totalCount: cached.page.totalCount,
          isStale: true,
          cachedAt: cached.storedAt,
        );
      }
    }
  }

  Future<List<TrackSummary>> loadAlbumTracks(String albumId) {
    final (:api, :address, :session) = _requireConnection();
    return api.getAlbumTracks(
      address: address,
      session: session,
      albumId: albumId,
    );
  }

  Future<SongPage> loadSongs({required int startIndex, required int limit}) {
    final (:api, :address, :session) = _requireConnection();
    return api.getSongs(
      address: address,
      session: session,
      startIndex: startIndex,
      limit: limit,
    );
  }

  Future<SongPage?> loadCachedSongs() async {
    final address = _state.serverAddress;
    final serverInfo = _state.serverInfo;
    final session = _state.session;
    if (!_state.canBrowseLibrary ||
        address == null ||
        serverInfo == null ||
        session == null) {
      return null;
    }
    CachedSongLibrary? cached;
    try {
      cached = await metadataCache.readSongs(
        SongLibraryCacheKey(serverId: serverInfo.id, userId: session.userId),
      );
    } catch (_) {
      return null;
    }
    if (cached == null) {
      return null;
    }
    return cached.page;
  }

  String? artworkFile(String? itemId) {
    final cache = artworkCache;
    final address = _state.serverAddress;
    if (cache is! RetainedArtworkCache ||
        itemId == null ||
        address == null ||
        accountKey == null)
      return null;
    return cache.latestPath(address.toString(), itemId);
  }

  Uint8List? peekArtwork(String? itemId, String? imageTag) {
    final key = '$accountKey:$itemId:$imageTag';
    final bytes = _artwork.remove(key);
    if (bytes != null) _artwork[key] = bytes;
    return bytes;
  }

  Future<Uint8List?> loadArtwork(String? itemId, String? imageTag) async {
    final address = _state.serverAddress;
    final session = _state.session;
    final account = accountKey;
    if (itemId == null || address == null || session == null || account == null)
      return null;
    final memory = peekArtwork(itemId, imageTag);
    if (memory != null) return memory;
    Uint8List? bytes;
    Uint8List? retained;
    final cache = artworkCache;
    if (cache is RetainedArtworkCache) {
      try {
        retained = await cache.readLatest(address.toString(), itemId);
      } catch (_) {}
    }
    try {
      if (_state.isConnected && _api != null) {
        bytes = await _api!.getArtwork(
          address: address,
          session: session,
          itemId: itemId,
          imageTag: imageTag,
        );
      } else if (imageTag != null) {
        bytes = await artworkCache.read(
          ArtworkCacheKey(
            server: address.toString(),
            itemId: itemId,
            imageTag: imageTag,
            maxWidth: 600,
          ),
        );
      }
    } catch (_) {
      // A temporary failure must not replace the durable image or cache a miss.
    }
    if (account != accountKey) return null;
    if (bytes == null) return retained;
    if (bytes.isNotEmpty && bytes.length <= 16 * 1024 * 1024) {
      final key = '$account:$itemId:$imageTag';
      _artworkBytes -= _artwork.remove(key)?.length ?? 0;
      _artwork[key] = bytes;
      _artworkBytes += bytes.length;
      while (_artwork.length > 128 || _artworkBytes > 16 * 1024 * 1024) {
        _artworkBytes -= _artwork.remove(_artwork.keys.first)!.length;
      }
    }
    return bytes;
  }

  Stream<SongPage> refreshSongs({
    int pageSize = 500,
    bool Function()? isCancelled,
  }) async* {
    if (pageSize <= 0) throw ArgumentError.value(pageSize, 'pageSize');
    final (:api, :address, :session) = _requireConnection();
    final serverId = _state.serverInfo!.id;
    final songs = <SongSummary>[];
    final seen = <String>{};
    var offset = 0;
    bool active() =>
        !(isCancelled?.call() ?? false) &&
        identical(_api, api) &&
        identical(_state.session, session) &&
        _state.isConnected;
    while (active()) {
      final page = await api.getSongs(
        address: address,
        session: session,
        startIndex: offset,
        limit: pageSize,
      );
      if (!active()) return;
      final next = page.nextStartIndex ?? offset + page.songs.length;
      if (next <= offset && offset < page.totalCount) {
        throw const JellyfinConnectionException(
          'Jellyfin returned an incomplete song library. Try refreshing again.',
        );
      }
      songs.addAll(page.songs.where((song) => seen.add(song.track.id)));
      final snapshot = SongPage(
        songs: List.unmodifiable(songs),
        totalCount: page.totalCount,
      );
      yield snapshot;
      if (!active()) return;
      if (next >= page.totalCount) {
        try {
          await metadataCache.writeSongs(
            SongLibraryCacheKey(serverId: serverId, userId: session.userId),
            snapshot,
          );
        } catch (_) {
          /* A cache failure must not block browsing. */
        }
        if (active()) _libraryChanges.add(null);
        return;
      }
      offset = next;
    }
  }

  Future<SongPage> refreshAllSongs({int pageSize = 500}) async {
    SongPage? last;
    await for (final page in refreshSongs(pageSize: pageSize)) {
      last = page;
    }
    if (last == null)
      throw const JellyfinConnectionException(
        'Your connection changed. Refresh the library again.',
      );
    return last;
  }

  Future<PlaylistPage> loadPlaylists({
    required int startIndex,
    int limit = 48,
  }) {
    final (:api, :address, :session) = _requireConnection();
    return api.getPlaylists(
      address: address,
      session: session,
      startIndex: startIndex,
      limit: limit,
    );
  }

  Stream<SongPage> loadPlaylistTracks(
    String playlistId, {
    bool Function()? isCancelled,
  }) async* {
    final (:api, :address, :session) = _requireConnection();
    final cacheKey = 'playlist:$accountKey:$playlistId';
    bool active() =>
        !(isCancelled?.call() ?? false) &&
        identical(_api, api) &&
        identical(_state.session, session) &&
        _state.isConnected;
    var cached = false;
    try {
      final saved = await contentCache.read(cacheKey);
      if (!active()) return;
      if (saved != null) {
        final page = decodePlaylistSnapshot(saved);
        cached = true;
        yield page;
      }
    } catch (_) {
      /* Ignore damaged or unavailable local snapshots. */
    }
    final songs = <SongSummary>[];
    var offset = 0;
    while (!(isCancelled?.call() ?? false) &&
        identical(_api, api) &&
        identical(_state.session, session) &&
        _state.isConnected) {
      final page = await api.getPlaylistTracks(
        address: address,
        session: session,
        playlistId: playlistId,
        startIndex: offset,
        limit: 500,
      );
      if ((isCancelled?.call() ?? false) ||
          !identical(_api, api) ||
          !identical(_state.session, session) ||
          !_state.isConnected)
        return;
      final next = page.nextStartIndex ?? offset + page.songs.length;
      if (next <= offset && offset < page.totalCount)
        throw const JellyfinConnectionException(
          'Jellyfin returned an incomplete playlist. Try again.',
        );
      songs.addAll(
        page.songs,
      ); // Playlist order and duplicate entries are intentional.
      final snapshot = SongPage(
        songs: List.unmodifiable(songs),
        totalCount: page.totalCount,
      );
      // Keep a complete saved queue visible while refreshing all its pages.
      if (!cached || next >= page.totalCount) yield snapshot;
      if (next >= page.totalCount) {
        if (active()) {
          try {
            await contentCache.write(
              cacheKey,
              encodePlaylistSnapshot(snapshot),
            );
          } catch (_) {}
        }
        return;
      }
      offset = next;
    }
  }

  Future<PlaylistSummary> createPlaylist(
    String name, {
    List<String> itemIds = const [],
  }) {
    final (:api, :address, :session) = _requireConnection();
    return api.createPlaylist(
      address: address,
      session: session,
      name: name,
      itemIds: itemIds,
    );
  }

  Future<bool> canEditPlaylist(String playlistId) {
    final (:api, :address, :session) = _requireConnection();
    return api.canEditPlaylist(
      address: address,
      session: session,
      playlistId: playlistId,
    );
  }

  Future<void> renamePlaylist(String playlistId, String name) {
    final (:api, :address, :session) = _requireConnection();
    return api.renamePlaylist(
      address: address,
      session: session,
      playlistId: playlistId,
      name: name,
    );
  }

  Future<PlaylistSummary> loadPlaylistDetails(String playlistId) {
    final (:api, :address, :session) = _requireConnection();
    return api.getPlaylistDetails(
      address: address,
      session: session,
      playlistId: playlistId,
    );
  }

  Future<PlaylistSummary> updatePlaylistDetails(
    String playlistId, {
    required String name,
    required String description,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) {
    final (:api, :address, :session) = _requireConnection();
    return api.updatePlaylistDetails(
      address: address,
      session: session,
      playlistId: playlistId,
      name: name,
      description: description,
      imageBytes: imageBytes,
      imageMimeType: imageMimeType,
    );
  }

  Future<void> addPlaylistSongs(String playlistId, List<String> itemIds) {
    final (:api, :address, :session) = _requireConnection();
    return api.addPlaylistSongs(
      address: address,
      session: session,
      playlistId: playlistId,
      itemIds: itemIds,
    );
  }

  Future<void> removePlaylistEntry(String playlistId, String entryId) {
    final (:api, :address, :session) = _requireConnection();
    return api.removePlaylistEntry(
      address: address,
      session: session,
      playlistId: playlistId,
      entryId: entryId,
    );
  }

  Future<void> movePlaylistEntry(
    String playlistId,
    String entryId,
    int newIndex, {
    required List<String?> expectedEntries,
  }) async {
    final (:api, :address, :session) = _requireConnection();
    final entries = <String?>[];
    var offset = 0;
    while (true) {
      final page = await api.getPlaylistTracks(
        address: address,
        session: session,
        playlistId: playlistId,
        startIndex: offset,
        limit: 100,
      );
      if (page.songs.any((song) => song.entryId == null))
        throw const JellyfinConnectionException(
          'Could not verify every playlist entry. Refresh before reordering.',
        );
      entries.addAll(page.songs.map((song) => song.entryId));
      final next = page.nextStartIndex ?? offset + page.songs.length;
      if (next >= page.totalCount) {
        if (entries.length != page.totalCount)
          throw const JellyfinConnectionException(
            'This playlist includes unavailable entries. Refresh before reordering.',
          );
        break;
      }
      if (next <= offset)
        throw const JellyfinConnectionException(
          'Could not verify the current playlist order. Refresh and try again.',
        );
      offset = next;
    }
    if (!identical(_api, api) ||
        !identical(_state.session, session) ||
        entries.length != expectedEntries.length ||
        entries.indexed.any((entry) => entry.$2 != expectedEntries[entry.$1]))
      throw const JellyfinConnectionException(
        'This playlist changed on another device. Refresh before reordering.',
      );
    if (newIndex < 0 ||
        newIndex >= entries.length ||
        !entries.contains(entryId))
      throw const JellyfinConnectionException(
        'The song position was invalid. Refresh and try again.',
      );
    await api.movePlaylistEntry(
      address: address,
      session: session,
      playlistId: playlistId,
      entryId: entryId,
      newIndex: newIndex,
    );
  }

  Future<void> deletePlaylist(String playlistId) {
    final (:api, :address, :session) = _requireConnection();
    return api.deletePlaylist(
      address: address,
      session: session,
      playlistId: playlistId,
    );
  }

  Future<LibrarySearchResults> searchLibrary(String query, {int limit = 24}) {
    final (:api, :address, :session) = _requireConnection();
    return api.searchLibrary(
      address: address,
      session: session,
      query: query,
      limit: limit,
    );
  }

  Future<ArtistPage> loadArtists({
    required int startIndex,
    required int limit,
  }) => watchArtists(startIndex: startIndex, limit: limit).last;

  Stream<ArtistPage> watchArtists({
    required int startIndex,
    required int limit,
  }) async* {
    final api = _api, address = _state.serverAddress, session = _state.session;
    final serverId = _state.serverInfo?.id;
    final request = _connectionRequest;
    bool active() =>
        request == _connectionRequest &&
        identical(_api, api) &&
        identical(_state.session, session) &&
        _state.canBrowseLibrary;
    if (!_state.canBrowseLibrary ||
        api == null ||
        address == null ||
        session == null ||
        serverId == null)
      throw const JellyfinConnectionException(
        'Connect before browsing artists.',
      );
    final key = ArtistPageCacheKey(
      serverId: serverId,
      userId: session.userId,
      startIndex: startIndex,
      limit: limit,
    );
    CachedArtistPage? cached;
    try {
      cached = await metadataCache.readArtistPage(key);
    } catch (_) {}
    if (!active()) return;
    if (cached != null) yield cached.page;
    if (!active() || !_state.isConnected) return;
    try {
      final page = await api.getArtists(
        address: address,
        session: session,
        startIndex: startIndex,
        limit: limit,
      );
      if (!active()) return;
      yield page;
      if (!active()) return;
      try {
        await metadataCache.writeArtistPage(key, page);
      } catch (_) {}
    } catch (_) {
      if (cached == null) rethrow;
    }
  }

  /// One cached catalogue, built from every source page and individual credits.
  /// The UI never has to author a page or know a server-specific artist ID.
  Stream<List<ArtistSummary>> watchArtistCatalog() async* {
    final account = accountKey;
    if (account == null) return;
    bool active() => accountKey == account;
    final key = 'artist-catalog-v1:$account';
    List<ArtistSummary>? saved;
    try {
      final json = await contentCache.read(key);
      if (json != null)
        saved = (jsonDecode(json) as List)
            .map(
              (item) => ArtistSummary(
                id: item['id'] as String,
                name: item['name'] as String,
                artworkId: item['artworkId'] as String?,
                imageTag: item['imageTag'] as String?,
              ),
            )
            .toList();
    } catch (_) {}
    if (!active()) return;
    if (saved != null) yield saved;
    final cachedSongs = await loadCachedSongs();
    if (!active()) return;
    if (!_state.isConnected) {
      if (saved == null && cachedSongs != null)
        yield artistCatalog([], songs: cachedSongs.songs);
      return;
    }
    final (:api, :address, :session) = _requireConnection();
    final sources = <ArtistSummary>[];
    try {
      var offset = 0;
      while (active()) {
        final page = await api.getArtists(
          address: address,
          session: session,
          startIndex: offset,
          limit: 500,
        );
        if (!active()) return;
        sources.addAll(page.artists);
        offset += page.artists.length;
        if (offset >= page.totalCount) break;
        if (page.artists.isEmpty)
          throw const JellyfinConnectionException(
            'The artist library was incomplete. Try refreshing.',
          );
      }
      if (!active()) return;
      final catalog = artistCatalog(sources, songs: cachedSongs?.songs ?? []);
      yield catalog;
      if (!active()) return;
      try {
        await contentCache.write(
          key,
          jsonEncode(
            catalog
                .map(
                  (a) => {
                    'id': a.id,
                    'name': a.name,
                    'artworkId': a.artworkId,
                    'imageTag': a.imageTag,
                  },
                )
                .toList(),
          ),
        );
      } catch (_) {}
    } catch (_) {
      if (saved == null) rethrow;
    }
  }

  Stream<List<SongSummary>> watchArtistSongs(String name) async* {
    final account = accountKey;
    final cached = await loadCachedSongs();
    if (accountKey != account) return;
    if (cached != null) yield songsForArtist(name, cached.songs);
    if (!_state.isConnected) return;
    try {
      if (_artistLibraryRefresh == null ||
          _artistLibraryRefreshAccount != account) {
        _artistLibraryRefreshAccount = account;
        final pending = refreshAllSongs();
        _artistLibraryRefresh = pending;
        unawaited(
          pending.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
            if (identical(_artistLibraryRefresh, pending))
              _artistLibraryRefresh = null;
          }),
        );
      }
      final page = await _artistLibraryRefresh!;
      if (accountKey == account) yield songsForArtist(name, page.songs);
    } catch (_) {
      if (cached == null) rethrow;
    }
  }

  Future<List<AlbumSummary>> loadArtistAlbums(String artistId) {
    final (:api, :address, :session) = _requireConnection();
    return api.getArtistAlbums(
      address: address,
      session: session,
      artistId: artistId,
    );
  }

  Future<TrackLyrics?> loadLyrics(
    String trackId, {
    String? title,
    String? artist,
    Duration duration = Duration.zero,
    Future<TrackLyrics?> Function()? libraryLoader,
  }) async {
    TrackLyrics? libraryLyrics;
    if (libraryLoader != null || _state.isConnected) {
      try {
        if (libraryLoader != null) {
          // A guest reads the host's shared library through its session, never
          // through an unrelated account saved on the guest's own device.
          libraryLyrics = await libraryLoader().timeout(
            const Duration(seconds: 3),
          );
        } else {
          final (:api, :address, :session) = _requireConnection();
          libraryLyrics = await api
              .getLyrics(address: address, session: session, trackId: trackId)
              .timeout(const Duration(seconds: 3));
        }
        if (libraryLyrics?.hasTiming == true) return libraryLyrics;
      } catch (_) {
        if (lyricsProvider == null) rethrow;
      }
    }
    if (title == null || artist == null || lyricsProvider == null)
      return libraryLyrics;
    try {
      final external = await lyricsProvider!.find(
        title: title,
        artist: artist,
        duration: duration,
      );
      if (external?.hasTiming == true) return external;
      return libraryLyrics?.lines.isNotEmpty == true ? libraryLyrics : external;
    } catch (_) {
      if (libraryLyrics?.lines.isNotEmpty == true) return libraryLyrics;
      rethrow;
    }
  }

  JellyfinAudioStreamSource createDirectPlaySource(String trackId) {
    final (:api, :address, :session) = _requireConnection();
    return api.createDirectPlaySource(
      address: address,
      session: session,
      itemId: trackId,
    );
  }

  Future<void> reportPlayback({
    required JellyfinPlaybackEvent event,
    required String itemId,
    required Duration position,
    required double volume,
    required bool paused,
  }) {
    final (:api, :address, :session) = _requireConnection();
    return api.reportPlayback(
      address: address,
      session: session,
      event: event,
      itemId: itemId,
      position: position,
      volume: volume,
      paused: paused,
    );
  }

  ({JellyfinApi api, JellyfinServerAddress address, JellyfinSession session})
  _requireConnection() {
    final api = _api;
    final address = _state.serverAddress;
    final session = _state.session;
    if (!_state.isConnected ||
        api == null ||
        address == null ||
        session == null) {
      throw const JellyfinConnectionException(
        'Connect to Jellyfin before loading your library.',
      );
    }
    return (api: api, address: address, session: session);
  }

  void _emit(JellyfinConnectionState state) {
    final previousAccount = accountKey;
    _state = state;
    if (previousAccount != accountKey) {
      _artwork.clear();
      _artworkBytes = 0;
    }
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  Future<void> dispose() async {
    ++_connectionRequest;
    _api?.close();
    await _libraryChanges.close();
    await _states.close();
  }
}
