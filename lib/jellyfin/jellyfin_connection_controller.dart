import 'dart:async';

import '../library/album_summary.dart';
import '../library/track_summary.dart';
import 'jellyfin_api.dart';
import 'jellyfin_credential_store.dart';

typedef JellyfinApiFactory = JellyfinApi Function(String deviceId);

enum JellyfinConnectionStatus { idle, connecting, connected, disconnecting }

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
}

class JellyfinConnectionController {
  JellyfinConnectionController({
    required JellyfinApiFactory apiFactory,
    required JellyfinCredentialStore credentialStore,
  }) : _apiFactory = apiFactory,
       _credentialStore = credentialStore;

  final JellyfinApiFactory _apiFactory;
  final JellyfinCredentialStore _credentialStore;
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
    try {
      final saved = await _credentialStore.readConnection();
      if (saved == null) {
        _emit(const JellyfinConnectionState());
        return;
      }
      final address = JellyfinServerAddress.parse(saved.serverAddress);
      final deviceId = await _credentialStore.getOrCreateDeviceId();
      final api = _apiFactory(deviceId);
      _api?.close();
      _api = api;
      final session = JellyfinSession(
        accessToken: saved.accessToken,
        userId: saved.userId,
        userName: saved.userName,
      );
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
      await _credentialStore.deleteConnection();
      _emit(JellyfinConnectionState(errorMessage: error.message));
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

  Future<List<AlbumSummary>> loadRecentlyAddedAlbums({int limit = 10}) async {
    final (:api, :address, :session) = _requireConnection();
    return api.getRecentlyAddedAlbums(
      address: address,
      session: session,
      limit: limit,
    );
  }

  Future<AlbumPage> loadAlbums({
    required AlbumSort sort,
    required int startIndex,
    int limit = 24,
  }) {
    final (:api, :address, :session) = _requireConnection();
    return api.getAlbums(
      address: address,
      session: session,
      sort: sort,
      startIndex: startIndex,
      limit: limit,
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
