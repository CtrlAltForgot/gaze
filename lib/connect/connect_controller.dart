import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import 'gaze_service_api.dart';

abstract interface class ConnectPreferences {
  Future<String?> read(String serverId);
  Future<void> write(String serverId, String address);
}

class SecureConnectPreferences implements ConnectPreferences {
  const SecureConnectPreferences();
  @override
  Future<String?> read(String serverId) =>
      const FlutterSecureStorage().read(key: 'gaze.service.$serverId');
  @override
  Future<void> write(String serverId, String address) =>
      const FlutterSecureStorage().write(
        key: 'gaze.service.$serverId',
        value: address,
      );
}

abstract interface class SignInBrowser {
  Future<void> open(Uri uri);
}

class DesktopSignInBrowser implements SignInBrowser {
  const DesktopSignInBrowser();
  @override
  Future<void> open(Uri uri) async {
    if (uri.scheme != 'https' || uri.host != 'accounts.spotify.com')
      throw const GazeServiceException(
        'Spotify returned an invalid sign-in address.',
      );
    final executable = Platform.isLinux
        ? 'xdg-open'
        : Platform.isMacOS
        ? 'open'
        : Platform.isWindows
        ? 'rundll32'
        : null;
    if (executable == null)
      throw const GazeServiceException(
        'Open Spotify sign-in on a supported desktop.',
      );
    final result = await Process.run(executable, [
      if (Platform.isWindows) 'url.dll,FileProtocolHandler',
      uri.toString(),
    ]);
    if (result.exitCode != 0)
      throw const GazeServiceException(
        'The browser could not open Spotify. Check your default browser and try again.',
      );
  }
}

class ConnectController extends ChangeNotifier {
  ConnectController({
    required this.connection,
    required this.api,
    this.preferences = const SecureConnectPreferences(),
    this.browser = const DesktopSignInBrowser(),
  }) {
    _subscription = connection.states.listen((_) => _accountChanged());
    unawaited(_accountChanged());
  }
  final JellyfinConnectionController connection;
  final GazeServiceApi api;
  final ConnectPreferences preferences;
  final SignInBrowser browser;
  late StreamSubscription<JellyfinConnectionState> _subscription;
  Timer? _timer;
  HttpServer? _callback;
  Uri? address;
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> playlists = [];
  String? error;
  bool busy = false;
  bool refreshing = false;
  bool signingIn = false;
  bool _disposed = false;
  int _generation = 0;
  String? _accountKey;
  Map<String, dynamic> get spotify =>
      snapshot?['spotify'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get synopti =>
      snapshot?['synopti'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get artwork =>
      snapshot?['artwork'] as Map<String, dynamic>? ?? {};
  List<Map<String, dynamic>> get jobs => (snapshot?['jobs'] as List? ?? [])
      .whereType<Map<String, dynamic>>()
      .where((job) => !['ready', 'ignored'].contains(job['status']))
      .toList();
  int get savedImportCount =>
      (snapshot?['jobCounts'] as Map<String, dynamic>?)?['saved'] as int? ??
      (snapshot?['jobs'] as List? ?? [])
          .where((job) => job is Map && job['status'] == 'ready')
          .length;
  List<Map<String, dynamic>> get sources =>
      (snapshot?['sources'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
  String get suggestedAddress {
    final jellyfin = connection.state.serverAddress?.toString();
    if (jellyfin == null) return '';
    final uri = Uri.parse(jellyfin);
    return uri
        .replace(port: 8097, path: '', query: null, fragment: null)
        .toString();
  }

  Future<void> _accountChanged() async {
    final state = connection.state;
    final key = state.session == null
        ? null
        : '${state.serverInfo?.id}/${state.session!.userId}/${state.isConnected}';
    if (_accountKey == key) {
      _notify();
      return;
    }
    _accountKey = key;
    _generation++;
    _timer?.cancel();
    await _callback?.close(force: true);
    _callback = null;
    snapshot = null;
    playlists = [];
    error = null;
    address = null;
    busy = false;
    refreshing = false;
    signingIn = false;
    _notify();
    final generation = _generation;
    if (state.serverInfo?.id == null || !state.isConnected) return;
    String? saved;
    try {
      saved = await preferences.read(state.serverInfo!.id);
    } catch (_) {}
    if (_disposed || generation != _generation) return;
    if (saved != null) {
      address = Uri.tryParse(saved);
      await refresh();
      _startPolling();
    }
  }

  Future<void> connect(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      error = 'Enter the address of your gaze service.';
      _notify();
      return;
    }
    address = uri;
    await _action(() async {
      final data = await _request('/v1/state');
      snapshot = data;
      final id = connection.state.serverInfo?.id;
      if (id != null) await preferences.write(id, uri.toString());
    });
    if (snapshot != null) _startPolling();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(refresh()),
    );
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final session = connection.state.session;
    if (address == null || session == null || !connection.state.isConnected)
      throw const GazeServiceException(
        'Connect to Jellyfin to manage your imports.',
      );
    final generation = _generation;
    final value = await api.request(
      address!,
      session.accessToken,
      path,
      body: body,
    );
    if (_disposed || generation != _generation)
      throw const GazeServiceException('The connected account changed.');
    return value;
  }

  Future<void> refresh() async {
    if (refreshing ||
        address == null ||
        !connection.state.isConnected ||
        _disposed)
      return;
    refreshing = true;
    final generation = _generation;
    try {
      final value = await _request('/v1/state');
      if (generation == _generation) {
        snapshot = value;
        error = null;
      }
    } on GazeServiceException catch (e) {
      if (generation == _generation) error = e.message;
    } finally {
      if (generation == _generation) {
        refreshing = false;
        _notify();
      }
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (busy || _disposed) return;
    final generation = _generation;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } on GazeServiceException catch (e) {
      if (generation == _generation) error = e.message;
    } catch (_) {
      if (generation == _generation)
        error = 'gaze could not complete this connection. Try again.';
    } finally {
      if (generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> change(String path, Map<String, dynamic> body) =>
      _action(() async {
        await _request(path, body: body);
        snapshot = await _request('/v1/state');
      });
  Future<void> loadPlaylists() => _action(() async {
    final data = await _request('/v1/spotify/playlists');
    playlists = (data['items'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
  });
  Future<void> selectPlaylists(Set<String> ids) => _action(() async {
    for (final id in ids) {
      await _request('/v1/sources', body: {'id': id});
    }
    snapshot = await _request('/v1/state');
  });
  Future<void> signIn() => _action(() async {
    await _callback?.close(force: true);
    final generation = _generation;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _callback = server;
    final redirect = 'http://127.0.0.1:${server.port}/spotify/callback';
    final start = await _request(
      '/v1/spotify/start',
      body: {'redirectUri': redirect},
    );
    final state = start['state'] as String;
    signingIn = true;
    _notify();
    unawaited(() async {
      final deadline = Timer(const Duration(minutes: 5), () {
        if (generation == _generation) {
          signingIn = false;
          error = 'Spotify sign-in timed out. Try again.';
          _notify();
        }
        unawaited(server.close(force: true));
      });
      try {
        await for (final request in server) {
          if (request.uri.path != '/spotify/callback' ||
              request.uri.queryParameters['state'] != state) {
            request.response.statusCode = 400;
            await request.response.close();
            continue;
          }
          final code = request.uri.queryParameters['code'];
          try {
            if (code == null)
              throw const GazeServiceException(
                'Spotify sign-in was cancelled.',
              );
            await _request(
              '/v1/spotify/complete',
              body: {'state': state, 'code': code},
            );
            request.response.headers.contentType = ContentType.html;
            request.response.write(
              '<!doctype html><meta charset="utf-8"><title>gaze</title><body style="background:#111216;color:#eee;font:18px system-ui;padding:12vh 10vw"><h1>Spotify is connected.</h1><p>You can return to gaze and choose your playlists.</p>',
            );
            await refresh();
          } on GazeServiceException catch (e) {
            if (generation == _generation) error = e.message;
            request.response.statusCode = 400;
            request.response.write(
              'Spotify could not connect. Return to gaze for details.',
            );
          }
          await request.response.close();
          break;
        }
      } catch (_) {
      } finally {
        deadline.cancel();
        await server.close(force: true);
        if (generation == _generation) {
          signingIn = false;
          _notify();
        }
      }
    }());
    try {
      await browser.open(Uri.parse(start['url'] as String));
    } catch (_) {
      await server.close(force: true);
      signingIn = false;
      rethrow;
    }
  });
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    unawaited(_subscription.cancel());
    unawaited(_callback?.close(force: true));
    api.close();
    super.dispose();
  }
}
