import 'dart:async';

import 'playback_controller.dart';

/// Brief gain envelopes shared by the player bar, queue and system media keys.
/// The public volume is the listener's setting, never an intermediate fade.
class FadingPlaybackController implements PlaybackController {
  FadingPlaybackController(
    PlaybackController backend, {
    Future<void> Function(Duration)? delay,
  }) : _backend = backend,
       _delay = delay ?? Future<void>.delayed,
       _volume = backend.state.volume,
       _state = backend.state,
       _gain = _isActive(backend.state) ? 1 : 0 {
    _subscription = backend.states.listen(_receive);
  }

  static const fadeIn = Duration(milliseconds: 165);
  static const fadeOut = Duration(milliseconds: 150);
  static const trackFadeOut = Duration(milliseconds: 110);
  static const seekFadeOut = Duration(milliseconds: 50);
  static const seekFadeIn = Duration(milliseconds: 90);
  static const _steps = 16;

  final PlaybackController _backend;
  final Future<void> Function(Duration) _delay;
  final _states = StreamController<PlaybackSnapshot>.broadcast();
  late final StreamSubscription<PlaybackSnapshot> _subscription;
  PlaybackSnapshot _state;
  double _volume;
  double _gain;
  bool _disposed = false;
  Future<void> _pending = Future.value();
  Future<void> _volumeWrites = Future.value();
  int _seekRequest = 0;

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  static bool _isActive(PlaybackSnapshot state) =>
      state.status == PlaybackStatus.playing ||
      state.status == PlaybackStatus.buffering;

  void _receive(PlaybackSnapshot incoming) {
    if (_disposed) return;
    final next = incoming.copyWith(volume: _volume);
    // Suppress volume-only engine events. Otherwise every envelope step would
    // repaint the player and repeatedly persist a temporary volume setting.
    if (_state.status == next.status &&
        _state.position == next.position &&
        _state.duration == next.duration &&
        _state.volume == next.volume &&
        _state.sourceLabel == next.sourceLabel &&
        _state.completed == next.completed &&
        _state.errorMessage == next.errorMessage &&
        _state.title == next.title &&
        _state.artist == next.artist &&
        identical(_state.artworkBytes, next.artworkBytes) &&
        _state.itemId == next.itemId) {
      return;
    }
    _state = next;
    _states.add(next);
  }

  Future<void> _schedule(Future<void> Function() action) {
    if (_disposed) return Future.value();
    final result = _pending.then((_) async {
      if (_disposed) return;
      try {
        await action();
        _receive(_backend.state);
      } catch (_) {
        // A rejected command must not strand a still-playing engine at zero.
        if (!_disposed) await _setGain(_isActive(_backend.state) ? 1 : 0);
        rethrow;
      }
    });
    // Preserve the caller's error while keeping later commands usable.
    _pending = result.catchError((Object _) {});
    return result;
  }

  Future<void> _writeVolume() {
    final write = _volumeWrites.then((_) async {
      if (!_disposed) await _backend.setVolume(_volume * _gain);
    });
    _volumeWrites = write.catchError((Object _) {});
    return write;
  }

  Future<void> _setGain(double gain) {
    _gain = gain;
    return _writeVolume();
  }

  Future<void> _fadeTo(double target, Duration duration) async {
    if (_disposed) return;
    if (_gain == target || _volume == 0) {
      await _setGain(target);
      return;
    }
    final start = _gain;
    for (var step = 1; step <= _steps; step++) {
      final startMicros = duration.inMicroseconds * (step - 1) ~/ _steps;
      final endMicros = duration.inMicroseconds * step ~/ _steps;
      await _delay(Duration(microseconds: endMicros - startMicros));
      if (_disposed) return;
      final t = step / _steps;
      // Smoothstep has no abrupt slope at either end of the transition.
      final eased = t * t * (3 - 2 * t);
      await _setGain(start + (target - start) * eased);
    }
  }

  Future<void> _load(Future<void> Function() load) => _schedule(() async {
    if (_isActive(_backend.state)) {
      await _fadeTo(0, trackFadeOut);
    } else {
      await _setGain(0);
    }
    if (_disposed) return;
    await load();
    // Sources load paused; the following Play owns the fade-in.
  });

  @override
  Future<void> loadLocalFile(String path) =>
      _load(() => _backend.loadLocalFile(path));

  @override
  Future<void> loadRemoteUrl(Uri url) =>
      _load(() => _backend.loadRemoteUrl(url));

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) =>
      _load(() => _backend.loadRemoteSource(source));

  @override
  Future<void> play() => _schedule(() async {
    if (_backend.state.sourceLabel == null ||
        _backend.state.status == PlaybackStatus.error)
      return;
    if (!_isActive(_backend.state)) {
      await _setGain(0);
      if (_disposed) return;
      await _backend.play();
    }
    if (_backend.state.status != PlaybackStatus.error) {
      await _fadeTo(1, fadeIn);
    }
  });

  @override
  Future<void> pause() => _schedule(() async {
    if (_isActive(_backend.state)) await _fadeTo(0, fadeOut);
    if (!_disposed) await _backend.pause();
  });

  @override
  Future<void> stop() => _schedule(() async {
    if (_isActive(_backend.state)) await _fadeTo(0, fadeOut);
    if (!_disposed) await _backend.stop();
  });

  @override
  Future<void> seek(Duration position) {
    final request = ++_seekRequest;
    return _schedule(() async {
      // Dragging the progress slider can enqueue many positions. Only seek to
      // the latest waiting position, rather than replaying every drag event.
      if (request != _seekRequest) return;
      final wasPlaying = _isActive(_backend.state);
      if (wasPlaying) await _fadeTo(0, seekFadeOut);
      if (_disposed) return;
      if (request == _seekRequest) await _backend.seek(position);
      if (wasPlaying && _backend.state.status != PlaybackStatus.error) {
        await _fadeTo(1, seekFadeIn);
      }
    });
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed || !volume.isFinite) return;
    _volume = volume.clamp(0, 1);
    _receive(_backend.state);
    // An in-flight envelope reads this latest setting on its next step.
    await _writeVolume();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _pending;
    await _volumeWrites;
    await _subscription.cancel();
    await _backend.dispose();
    await _states.close();
  }
}
