import 'dart:async';

import 'playback_controller.dart';

class PlaybackQueueState {
  const PlaybackQueueState({this.items = const [], this.currentIndex = -1});

  final List<RemotePlaybackSource> items;
  final int currentIndex;

  bool get hasPrevious => currentIndex > 0;
  bool get hasNext => currentIndex >= 0 && currentIndex + 1 < items.length;
}

class PlaybackQueueController {
  PlaybackQueueController({required PlaybackController playbackController})
    : _playbackController = playbackController {
    _playbackSubscription = playbackController.states.listen((playback) {
      if (playback.completed && !_completionHandled) {
        _completionHandled = true;
        unawaited(next());
      } else if (!playback.completed) {
        _completionHandled = false;
      }
    });
  }

  final PlaybackController _playbackController;
  final StreamController<PlaybackQueueState> _states =
      StreamController<PlaybackQueueState>.broadcast();
  late final StreamSubscription<PlaybackSnapshot> _playbackSubscription;
  PlaybackQueueState _state = const PlaybackQueueState();
  bool _completionHandled = false;

  static const previousRestartThreshold = Duration(seconds: 5);

  PlaybackQueueState get state => _state;
  Stream<PlaybackQueueState> get states => _states.stream;

  Future<void> playAlbum(
    List<RemotePlaybackSource> items, {
    required int startIndex,
  }) async {
    if (items.isEmpty || startIndex < 0 || startIndex >= items.length) {
      return;
    }
    _emit(
      PlaybackQueueState(
        items: List.unmodifiable(items),
        currentIndex: startIndex,
      ),
    );
    await _openCurrent();
  }

  Future<void> restore(
    List<RemotePlaybackSource> items, {
    required int currentIndex,
    required double volume,
  }) async {
    if (items.isEmpty || currentIndex < 0 || currentIndex >= items.length) {
      return;
    }
    _emit(
      PlaybackQueueState(
        items: List.unmodifiable(items),
        currentIndex: currentIndex,
      ),
    );
    _completionHandled = false;
    await _playbackController.loadRemoteSource(items[currentIndex]);
    await _playbackController.setVolume(volume.clamp(0, 1));
  }

  Future<void> previous() async {
    if (_playbackController.state.position > previousRestartThreshold) {
      await _playbackController.seek(Duration.zero);
      return;
    }
    if (!_state.hasPrevious) {
      return;
    }
    _emit(
      PlaybackQueueState(
        items: _state.items,
        currentIndex: _state.currentIndex - 1,
      ),
    );
    await _openCurrent();
  }

  Future<void> next() async {
    if (!_state.hasNext) {
      return;
    }
    _emit(
      PlaybackQueueState(
        items: _state.items,
        currentIndex: _state.currentIndex + 1,
      ),
    );
    await _openCurrent();
  }

  Future<void> _openCurrent() async {
    _completionHandled = false;
    await _playbackController.loadRemoteSource(
      _fromBeginning(_state.items[_state.currentIndex]),
    );
    await _playbackController.play();
  }

  RemotePlaybackSource _fromBeginning(RemotePlaybackSource source) {
    return RemotePlaybackSource(
      uri: source.uri,
      headers: source.headers,
      title: source.title,
      artist: source.artist,
      itemId: source.itemId,
      artworkBytes: source.artworkBytes,
    );
  }

  void _emit(PlaybackQueueState state) {
    _state = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  Future<void> dispose() async {
    await _playbackSubscription.cancel();
    await _states.close();
  }
}
