import 'dart:async';

enum PlaybackStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  buffering,
  stopped,
  completed,
  error,
}

class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.status = PlaybackStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1,
    this.sourceLabel,
    this.completed = false,
    this.errorMessage,
  });

  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final double volume;
  final String? sourceLabel;
  final bool completed;
  final String? errorMessage;

  PlaybackSnapshot copyWith({
    PlaybackStatus? status,
    Duration? position,
    Duration? duration,
    double? volume,
    String? sourceLabel,
    bool? completed,
    String? errorMessage,
    bool clearError = false,
  }) {
    return PlaybackSnapshot(
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      sourceLabel: sourceLabel ?? this.sourceLabel,
      completed: completed ?? this.completed,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

abstract interface class PlaybackController {
  PlaybackSnapshot get state;

  Stream<PlaybackSnapshot> get states;

  Future<void> loadLocalFile(String path);

  Future<void> loadRemoteUrl(Uri url);

  Future<void> play();

  Future<void> pause();

  Future<void> stop();

  Future<void> seek(Duration position);

  Future<void> setVolume(double volume);

  Future<void> dispose();
}
