import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'playback_controller.dart';

class MediaKitPlaybackController implements PlaybackController {
  MediaKitPlaybackController({Player? player}) : _player = player ?? Player() {
    _subscriptions = [
      _player.stream.position.listen((position) {
        if (!_openingSource) {
          _emit(_state.copyWith(position: position));
        }
      }),
      _player.stream.duration.listen((duration) {
        if (!_openingSource) {
          _emit(_state.copyWith(duration: duration));
        }
      }),
      _player.stream.volume.listen(
        (volume) => _emit(_state.copyWith(volume: volume / 100)),
      ),
      _player.stream.playing.listen((playing) {
        if (playing) {
          _emit(_state.copyWith(status: PlaybackStatus.playing));
        } else if (_state.status == PlaybackStatus.playing) {
          _emit(_state.copyWith(status: PlaybackStatus.paused));
        }
      }),
      _player.stream.buffering.listen((buffering) {
        if (buffering) {
          _emit(_state.copyWith(status: PlaybackStatus.buffering));
        } else if (_state.status == PlaybackStatus.buffering) {
          _emit(
            _state.copyWith(
              status: _player.state.playing
                  ? PlaybackStatus.playing
                  : PlaybackStatus.ready,
            ),
          );
        }
      }),
      _player.stream.completed.listen((completed) {
        if (completed) {
          _emit(
            _state.copyWith(status: PlaybackStatus.completed, completed: true),
          );
        }
      }),
      _player.stream.error.listen(
        (message) => _emit(
          _state.copyWith(status: PlaybackStatus.error, errorMessage: message),
        ),
      ),
    ];
  }

  final Player _player;
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  late final List<StreamSubscription<dynamic>> _subscriptions;
  PlaybackSnapshot _state = const PlaybackSnapshot();
  bool _openingSource = false;

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  Future<void> loadLocalFile(String path) async {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      _reportError('Choose a local audio file first.');
      return;
    }

    await _load(Uri.file(trimmedPath).toString(), trimmedPath);
  }

  @override
  Future<void> loadRemoteUrl(Uri url) async {
    if (!url.hasAuthority || (url.scheme != 'http' && url.scheme != 'https')) {
      _reportError('Enter a complete HTTP or HTTPS audio URL.');
      return;
    }

    await loadRemoteSource(
      RemotePlaybackSource(uri: url, title: url.toString(), artist: ''),
    );
  }

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) async {
    final url = source.uri;
    if (!url.hasAuthority || (url.scheme != 'http' && url.scheme != 'https')) {
      _reportError('The remote audio source is not a valid HTTP or HTTPS URL.');
      return;
    }
    _openingSource = true;
    _emit(
      PlaybackSnapshot(
        status: PlaybackStatus.loading,
        volume: _state.volume,
        sourceLabel: source.title,
        title: source.title,
        artist: source.artist,
        artworkBytes: source.artworkBytes,
        itemId: source.itemId,
        position: source.startPosition,
      ),
    );
    try {
      await _run(() async {
        await _player.open(
          Media(
            url.toString(),
            httpHeaders: source.headers,
            start: source.startPosition > Duration.zero
                ? source.startPosition
                : null,
          ),
          play: false,
        );
        _emit(
          _state.copyWith(
            status: PlaybackStatus.ready,
            position: _player.state.position,
            duration: _player.state.duration,
            clearError: true,
          ),
        );
      });
    } finally {
      _openingSource = false;
    }
  }

  Future<void> _load(String source, String label) async {
    _openingSource = true;
    _emit(
      PlaybackSnapshot(
        status: PlaybackStatus.loading,
        volume: _state.volume,
        sourceLabel: label,
      ),
    );

    try {
      await _run(() async {
        await _player.open(Media(source), play: false);
        _emit(
          _state.copyWith(
            status: PlaybackStatus.ready,
            position: _player.state.position,
            duration: _player.state.duration,
            clearError: true,
          ),
        );
      });
    } finally {
      _openingSource = false;
    }
  }

  @override
  Future<void> play() => _run(_player.play);

  @override
  Future<void> pause() => _run(_player.pause);

  @override
  Future<void> stop() async {
    await _run(() async {
      await _player.stop();
      _emit(
        _state.copyWith(
          status: PlaybackStatus.stopped,
          position: Duration.zero,
          completed: false,
          clearError: true,
        ),
      );
    });
  }

  @override
  Future<void> seek(Duration position) => _run(() => _player.seek(position));

  @override
  Future<void> setVolume(double volume) {
    final normalizedVolume = volume.clamp(0.0, 1.0);
    return _run(() => _player.setVolume(normalizedVolume * 100));
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      _reportError(error.toString());
    }
  }

  void _reportError(String message) {
    _emit(_state.copyWith(status: PlaybackStatus.error, errorMessage: message));
  }

  void _emit(PlaybackSnapshot snapshot) {
    _state = snapshot;
    if (!_states.isClosed) {
      _states.add(snapshot);
    }
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _states.close();
  }
}
