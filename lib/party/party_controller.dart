import 'dart:async';
import 'package:flutter/foundation.dart';
import '../connect/connect_controller.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_queue_controller.dart';
import 'party_api.dart';

class PartyController extends ChangeNotifier {
  PartyController({
    required this.api,
    required this.connect,
    required this.playback,
    required this.queue,
  }) {
    _accountSubscription = connect.connection.states.listen((_) {
      if (hosting && connect.connection.accountKey != _hostAccount)
        unawaited(leave());
    });
  }
  final PartyApi api;
  final ConnectController connect;
  final PlaybackController playback;
  final PlaybackQueueController queue;
  StreamSubscription? _accountSubscription;
  Timer? _timer;
  Future<void>? _applying;
  Uri? _server;
  String? _id, _token, inviteUrl, _hostAccount;
  Map<String, dynamic>? snapshot;
  String? error;
  bool busy = false, hosting = false;
  bool get active => _id != null;
  bool get following => active && !hosting;
  bool _disposed = false, _polling = false;
  int _generation = 0, _revision = -1, _guestIndex = -1;
  String? _loadedTrack;
  List<String> _lastQueue = [];
  PlaybackQueueState? _savedQueue;
  PlaybackSnapshot? _savedPlayback;
  int _lastSuccess = 0;
  final Map<String, Uint8List> _artwork = {};
  String get hostName => snapshot?['hostName'] as String? ?? 'Your host';
  List<String> get listeners =>
      (snapshot?['listeners'] as List? ?? []).whereType<String>().toList();
  bool get connected => snapshot?['connected'] == true && error == null;
  bool get canHost =>
      connect.address != null &&
      connect.connection.state.isConnected &&
      queue.state.items.isNotEmpty &&
      queue.state.items.length <= 1000 &&
      queue.state.items.every((s) => s.itemId != null);

  Map<String, dynamic> _hostState({bool includeQueue = false}) {
    final state = queue.state;
    final current = playback.state;
    if (state.currentIndex < 0 ||
        state.items.isEmpty ||
        state.items.any((s) => s.itemId == null))
      throw const PartyException(
        'Play library songs before sharing your queue.',
      );
    return {
      if (includeQueue) 'queue': state.items.map((s) => s.itemId!).toList(),
      'index': state.currentIndex,
      'playing':
          current.status == PlaybackStatus.playing &&
          current.itemId == state.items[state.currentIndex].itemId,
      'positionMs': current.itemId == state.items[state.currentIndex].itemId
          ? current.position.inMilliseconds
          : 0,
    };
  }

  Future<void> start() async {
    if (busy || active) return;
    busy = true;
    error = null;
    _notify();
    final generation = ++_generation;
    try {
      if (!canHost)
        throw const PartyException(
          'Connect your gaze service and play some library music first.',
        );
      final server = connect.address!;
      final session = connect.connection.state.session!;
      final account = connect.connection.accountKey;
      final data = await api.request(
        server,
        session.accessToken,
        '/v1/parties',
        body: _hostState(includeQueue: true),
      );
      if (_disposed ||
          generation != _generation ||
          account != connect.connection.accountKey) {
        await api.request(
          server,
          data['token'],
          '/v1/parties/${data['id']}/leave',
          body: {},
        );
        return;
      }
      _server = server;
      _id = data['id'];
      _token = data['token'];
      inviteUrl = data['inviteUrl'];
      snapshot = data;
      hosting = true;
      _hostAccount = account;
      _lastQueue = queue.state.items.map((s) => s.itemId!).toList();
      _beginPolling();
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> join(PartyInvite invite, String name) async {
    if (busy || active) return;
    busy = true;
    error = null;
    _notify();
    final generation = ++_generation;
    try {
      final data = await api.request(
        invite.server,
        invite.secret,
        '/v1/parties/${invite.id}/join',
        body: {'name': name.trim().isEmpty ? 'Listener' : name.trim()},
      );
      if (_disposed || generation != _generation) {
        await api.request(
          invite.server,
          data['token'],
          '/v1/parties/${invite.id}/leave',
          body: {},
        );
        return;
      }
      _savedQueue = queue.state;
      _savedPlayback = playback.state;
      await playback.pause();
      _server = invite.server;
      _id = invite.id;
      _token = data['token'];
      hosting = false;
      snapshot = data;
      queue.followingParty = true;
      await _synchronize(data, 0, generation);
      if (generation == _generation) _beginPolling();
    } catch (e) {
      if (active) await leave();
      error = e.toString();
    } finally {
      busy = false;
      _notify();
    }
  }

  void _beginPolling() {
    _lastSuccess = DateTime.now().millisecondsSinceEpoch;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (following &&
          DateTime.now().millisecondsSinceEpoch - _lastSuccess >= 5000) {
        unawaited(playback.pause());
      }
      unawaited(poll());
    });
    _notify();
  }

  Future<void> poll() async {
    if (_disposed || !active || _polling) return;
    _polling = true;
    final generation = _generation;
    final watch = Stopwatch()..start();
    try {
      final ids = hosting
          ? queue.state.items.map((s) => s.itemId ?? '').toList()
          : <String>[];
      final data = await api.request(
        _server!,
        _token!,
        '/v1/parties/$_id/state${hosting ? '' : '?revision=$_revision'}',
        body: hosting
            ? _hostState(includeQueue: !listEquals(ids, _lastQueue))
            : null,
      );
      if (_disposed || generation != _generation) return;
      snapshot = {...?snapshot, ...data};
      error = null;
      _lastSuccess = DateTime.now().millisecondsSinceEpoch;
      if (hosting) {
        _lastQueue = ids;
      } else {
        await _synchronize(
          snapshot!,
          watch.elapsedMilliseconds ~/ 2,
          generation,
        );
      }
    } on PartyException catch (e) {
      if (generation != _generation) return;
      if (e.status == 403 || e.status == 410) {
        await leave(notifyServer: false);
        error = e.message;
      } else {
        error = e.message;
        if (following &&
            DateTime.now().millisecondsSinceEpoch - _lastSuccess >= 5000)
          await playback.pause();
      }
    } catch (_) {
      if (generation == _generation) error = 'The session is reconnecting…';
    } finally {
      _polling = false;
      _notify();
    }
  }

  Future<void> _synchronize(
    Map<String, dynamic> data,
    int halfRtt,
    int generation,
  ) async {
    final operation = _apply(data, halfRtt, generation);
    _applying = operation;
    try {
      await operation;
    } finally {
      if (identical(_applying, operation)) _applying = null;
    }
  }

  Future<void> _apply(
    Map<String, dynamic> data,
    int halfRtt,
    int generation,
  ) async {
    final elapsed = Stopwatch()..start();
    final tracks = (data['queue'] as List).cast<Map<String, dynamic>>();
    final index = data['index'] as int;
    final track = tracks[index];
    final id = track['id'] as String;
    final playing = data['playing'] == true && data['connected'] == true;
    final position =
        (data['positionMs'] as num).toInt() +
        (playing
            ? (data['serverTime'] as int) - (data['updatedAt'] as int) + halfRtt
            : 0);
    final duration = (track['durationMs'] as num).toInt();
    final target = Duration(
      milliseconds: position.clamp(0, duration > 0 ? duration : 86400000),
    );
    final changed = _loadedTrack != id || _guestIndex != index;
    if (changed) {
      Uint8List? image = _artwork[id];
      if (image == null && track['hasArtwork'] == true) {
        image = await api.artwork(
          _server!.replace(path: '/v1/parties/$_id/artwork/$id'),
          _token!,
        );
        if (image != null) {
          if (_artwork.length >= 12) _artwork.remove(_artwork.keys.first);
          _artwork[id] = image;
        }
      }
      if (_disposed || generation != _generation) return;
      final source = _source(track, artwork: image, position: target);
      final volume = playback.state.volume;
      await playback.loadRemoteSource(source);
      await playback.setVolume(volume);
      if (_disposed || generation != _generation) return;
      _loadedTrack = id;
    }
    if (_revision != data['revision'] || _guestIndex != index) {
      queue.updatePartyQueue(
        tracks.map((t) => _source(t, artwork: _artwork[t['id']])).toList(),
        index,
      );
      _revision = data['revision'];
      _guestIndex = index;
    }
    if (changed ||
        (playback.state.position - target).abs() >
            const Duration(milliseconds: 700))
      await playback.seek(target + (playing ? elapsed.elapsed : Duration.zero));
    if (generation != _generation) return;
    if (playing && playback.state.status != PlaybackStatus.playing)
      await playback.play();
    if (!playing && playback.state.status != PlaybackStatus.paused)
      await playback.pause();
  }

  RemotePlaybackSource _source(
    Map<String, dynamic> track, {
    Uint8List? artwork,
    Duration position = Duration.zero,
  }) => RemotePlaybackSource(
    uri: _server!.replace(path: '/v1/parties/$_id/audio/${track['id']}'),
    headers: {'Authorization': 'Bearer $_token'},
    title: track['title'],
    artist: track['artist'],
    artworkBytes: artwork,
    startPosition: position,
    // Session audio is not a library item in the guest's account. Do not report
    // it to their Jellyfin or persist credentials in their saved queue.
  );

  Future<void> leave({bool notifyServer = true}) async {
    final server = _server, token = _token, id = _id, wasGuest = following;
    ++_generation;
    _timer?.cancel();
    _id = null;
    _token = null;
    _server = null;
    inviteUrl = null;
    snapshot = null;
    hosting = false;
    _loadedTrack = null;
    _guestIndex = -1;
    _revision = -1;
    _artwork.clear();
    // Let an already-started engine load finish before restoring local music.
    // Its generation check prevents it from playing or seeking afterward.
    try {
      await _applying;
    } catch (_) {}
    queue.followingParty = false;
    if (wasGuest) {
      final volume = playback.state.volume;
      await playback.stop();
      final saved = _savedQueue, state = _savedPlayback;
      if (saved != null && state != null && saved.items.isNotEmpty) {
        await queue.restore(
          saved.items,
          currentIndex: saved.currentIndex,
          volume: volume,
          shuffleEnabled: saved.shuffleEnabled,
          repeatMode: saved.repeatMode,
          originalOrder: saved.originalOrder,
        );
        await playback.seek(state.position);
        if (state.status == PlaybackStatus.playing) await playback.play();
      } else {
        queue.updatePartyQueue([], -1);
      }
      _savedQueue = null;
      _savedPlayback = null;
    }
    _notify();
    if (notifyServer && server != null && token != null && id != null) {
      try {
        await api.request(server, token, '/v1/parties/$id/leave', body: {});
      } catch (_) {}
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_accountSubscription?.cancel());
    api.close();
    super.dispose();
  }
}
