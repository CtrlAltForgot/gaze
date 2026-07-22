import 'dart:async';

import '../jellyfin/jellyfin_api.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../playback/playback_controller.dart';

class JellyfinPlaybackReporter {
  JellyfinPlaybackReporter({
    required PlaybackController playbackController,
    required JellyfinConnectionController connectionController,
  }) : _connectionController = connectionController {
    _subscription = playbackController.states.listen(_handlePlayback);
  }

  static const _progressInterval = Duration(seconds: 10);

  final JellyfinConnectionController _connectionController;
  late final StreamSubscription<PlaybackSnapshot> _subscription;
  Future<void> _pending = Future.value();
  PlaybackSnapshot? _previous;
  String? _activeItemId;
  Duration _lastProgress = Duration.zero;
  bool _stopped = true;

  void _handlePlayback(PlaybackSnapshot playback) {
    final previous = _previous;
    _previous = playback;
    final itemId = playback.itemId;
    if (previous?.itemId != null && itemId != previous!.itemId && !_stopped) {
      _enqueue(
        JellyfinPlaybackEvent.stopped,
        previous.itemId!,
        previous.position,
        previous.volume,
        false,
      );
      _stopped = true;
      _activeItemId = null;
    }
    if (itemId == null) return;

    if (playback.status == PlaybackStatus.playing) {
      if (_activeItemId != itemId || _stopped) {
        _activeItemId = itemId;
        _lastProgress = playback.position;
        _stopped = false;
        _enqueue(
          JellyfinPlaybackEvent.start,
          itemId,
          playback.position,
          playback.volume,
          false,
        );
      } else if ((playback.position - _lastProgress).abs() >=
          _progressInterval) {
        _lastProgress = playback.position;
        _enqueue(
          JellyfinPlaybackEvent.progress,
          itemId,
          playback.position,
          playback.volume,
          false,
        );
      }
    } else if (playback.status == PlaybackStatus.paused &&
        previous?.status != PlaybackStatus.paused &&
        !_stopped) {
      _lastProgress = playback.position;
      _enqueue(
        JellyfinPlaybackEvent.progress,
        itemId,
        playback.position,
        playback.volume,
        true,
      );
    } else if ((playback.status == PlaybackStatus.completed ||
            playback.status == PlaybackStatus.stopped ||
            playback.status == PlaybackStatus.error) &&
        !_stopped) {
      _stopped = true;
      _enqueue(
        JellyfinPlaybackEvent.stopped,
        itemId,
        playback.position,
        playback.volume,
        false,
      );
    }
  }

  void _enqueue(
    JellyfinPlaybackEvent event,
    String itemId,
    Duration position,
    double volume,
    bool paused,
  ) {
    _pending = _pending.then((_) async {
      try {
        await _connectionController.reportPlayback(
          event: event,
          itemId: itemId,
          position: position,
          volume: volume,
          paused: paused,
        );
      } on Exception {
        // Reporting must never interrupt local playback.
      }
    });
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await _pending;
  }
}
