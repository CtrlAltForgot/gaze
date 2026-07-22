import 'dart:async';

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
      await _credentialStore.writeAccessToken(session.accessToken);
      _emit(
        JellyfinConnectionState(
          status: JellyfinConnectionStatus.connected,
          serverAddress: address,
          serverInfo: serverInfo,
          session: session,
        ),
      );
    } on JellyfinConnectionException catch (error) {
      _emit(JellyfinConnectionState(errorMessage: error.message));
    } catch (_) {
      _emit(
        const JellyfinConnectionState(
          errorMessage: 'gaze could not securely save the Jellyfin session.',
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
      await _credentialStore.deleteAccessToken();
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
