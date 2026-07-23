import 'dart:async';

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
      isConnected || status == JellyfinConnectionStatus.offline;
}

class JellyfinConnectionController {
  JellyfinConnectionController({
    required JellyfinApiFactory apiFactory,
    required JellyfinCredentialStore credentialStore,
    this.artworkCache = const DisabledArtworkCache(),
    this.metadataCache = const DisabledLibraryMetadataCache(),
  }) : _apiFactory = apiFactory,
       _credentialStore = credentialStore;

  final JellyfinApiFactory _apiFactory;
  final JellyfinCredentialStore _credentialStore;
  final ArtworkCache artworkCache;
  final LibraryMetadataCache metadataCache;
  final StreamController<JellyfinConnectionState> _states =
      StreamController<JellyfinConnectionState>.broadcast();
  JellyfinConnectionState _state = const JellyfinConnectionState();
  JellyfinApi? _api;

  JellyfinConnectionState get state => _state;

  Stream<JellyfinConnectionState> get states => _states.stream;

  Future<SavedJellyfinProfile?> loadSavedProfile() =>
      _credentialStore.readProfile();

  Future<void> connect({
    required String serverAddress,
    required String userName,
    required String password,
  }) async {
    if (_state.status == JellyfinConnectionStatus.connecting) {
      return;
    }

    _emit(
      const JellyfinConnectionState(
        status: JellyfinConnectionStatus.connecting,
      ),
    );
    try {
      final address = JellyfinServerAddress.parse(serverAddress);
      final deviceId = await _credentialStore.getOrCreateDeviceId();
      _api?.close();
      final api = _apiFactory(deviceId);
      _api = api;
      final serverInfo = await api.getPublicServerInfo(address);
      final session = await api.authenticate(
        address: address,
        userName: userName,
        password: password,
      );
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
      _emit(JellyfinConnectionState(errorMessage: error.message));
    } catch (_) {
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
      if (saved == null) {
        _emit(const JellyfinConnectionState());
        return;
      }
      address = JellyfinServerAddress.parse(saved.serverAddress);
      final deviceId = await _credentialStore.getOrCreateDeviceId();
      final api = _apiFactory(deviceId);
      _api?.close();
      _api = api;
      session = JellyfinSession(
        accessToken: saved.accessToken,
        userId: saved.userId,
        userName: saved.userName,
      );
      final serverInfo = await api.getPublicServerInfo(address);
      await api.validateSession(address: address, session: session);
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
      _emit(
        JellyfinConnectionState(
          status: JellyfinConnectionStatus.connected,
          serverAddress: address,
          serverInfo: serverInfo,
          session: session,
        ),
      );
    } on JellyfinConnectionException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _credentialStore.deleteConnection();
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
    final api = _api;
    final address = _state.serverAddress;
    final session = _state.session;
    if (api == null || address == null || session == null) {
      return;
    }
    try {
      final serverInfo = await api.getPublicServerInfo(address);
      await api.validateSession(address: address, session: session);
      _emit(
        JellyfinConnectionState(
          status: JellyfinConnectionStatus.connected,
          serverAddress: address,
          serverInfo: serverInfo,
          session: session,
        ),
      );
    } on JellyfinConnectionException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _credentialStore.deleteConnection();
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
  }) async {
    final api = _api;
    final address = _state.serverAddress;
    final session = _state.session;
    if (!_state.canBrowseLibrary ||
        api == null ||
        address == null ||
        session == null) {
      throw const JellyfinConnectionException(
        'Connect to Jellyfin before browsing albums.',
      );
    }
    final serverId = _state.serverInfo!.id;
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
      // Cache availability must not block the live Jellyfin library.
    }
    if (cached != null && cached.isFreshAt(DateTime.now())) {
      return _hydrateCachedArtwork(
        cached,
        address,
        stale: _state.status == JellyfinConnectionStatus.offline,
      );
    }
    if (_state.status == JellyfinConnectionStatus.offline) {
      if (cached == null) {
        throw const JellyfinConnectionException(
          'This part of the library has not been saved on this device.',
        );
      }
      return _hydrateCachedArtwork(cached, address, stale: true);
    }
    try {
      final page = await api.getAlbums(
        address: address,
        session: session,
        sort: sort,
        startIndex: startIndex,
        limit: limit,
      );
      try {
        await metadataCache.writeAlbumPage(key, page);
      } catch (_) {
        // A live response remains usable if metadata persistence fails.
      }
      return page;
    } on JellyfinConnectionException {
      if (cached == null) {
        rethrow;
      }
      return _hydrateCachedArtwork(cached, address, stale: true);
    }
  }

  Future<AlbumPage> _hydrateCachedArtwork(
    CachedAlbumPage cached,
    JellyfinServerAddress address, {
    required bool stale,
  }) async {
    final albums = <AlbumSummary>[];
    for (final album in cached.page.albums) {
      final imageTag = album.imageTag;
      var artworkBytes = album.artworkBytes;
      if (imageTag != null) {
        try {
          artworkBytes = await artworkCache.read(
            ArtworkCacheKey(
              server: address.toString(),
              itemId: album.id,
              imageTag: imageTag,
              maxWidth: 600,
            ),
          );
        } catch (_) {
          // Missing artwork does not invalidate usable cached metadata.
        }
      }
      albums.add(
        AlbumSummary(
          id: album.id,
          title: album.title,
          artist: album.artist,
          year: album.year,
          imageTag: imageTag,
          artworkBytes: artworkBytes,
        ),
      );
    }
    return AlbumPage(
      albums: albums,
      totalCount: cached.page.totalCount,
      isStale: stale,
      cachedAt: cached.storedAt,
    );
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
  }) {
    final (:api, :address, :session) = _requireConnection();
    return api.getArtists(
      address: address,
      session: session,
      startIndex: startIndex,
      limit: limit,
    );
  }

  Future<List<AlbumSummary>> loadArtistAlbums(String artistId) {
    final (:api, :address, :session) = _requireConnection();
    return api.getArtistAlbums(
      address: address,
      session: session,
      artistId: artistId,
    );
  }

  Future<TrackLyrics?> loadLyrics(String trackId) {
    final (:api, :address, :session) = _requireConnection();
    return api.getLyrics(address: address, session: session, trackId: trackId);
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
    _state = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  Future<void> dispose() async {
    _api?.close();
    await _states.close();
  }
}
