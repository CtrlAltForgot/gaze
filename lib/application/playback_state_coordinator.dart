import 'dart:async';

import '../jellyfin/jellyfin_connection_controller.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_queue_controller.dart';
import '../storage/playback_state_store.dart';

class PlaybackStateCoordinator {
  PlaybackStateCoordinator({
    required PlaybackController playbackController,
    required PlaybackQueueController queueController,
    required JellyfinConnectionController connectionController,
    required PlaybackStateStore store,
    this.isFollowingParty,
  }) : _playbackController = playbackController,
       _queueController = queueController,
       _connectionController = connectionController,
       _store = store {
    _queueSubscription = queueController.states.listen((_) => _scheduleSave());
    _playbackSubscription = playbackController.states.listen(_handlePlayback);
    _connectionSubscription = connectionController.states.listen(
      _handleConnection,
    );
    if (connectionController.state.isConnected) {
      unawaited(_restore());
    }
  }

  static const _positionWriteInterval = Duration(seconds: 5);

  final PlaybackController _playbackController;
  final PlaybackQueueController _queueController;
  final JellyfinConnectionController _connectionController;
  final PlaybackStateStore _store;
  final bool Function()? isFollowingParty;
  late final StreamSubscription<PlaybackQueueState> _queueSubscription;
  late final StreamSubscription<PlaybackSnapshot> _playbackSubscription;
  late final StreamSubscription<JellyfinConnectionState>
  _connectionSubscription;
  Future<void> _pending = Future.value();
  Duration _lastSavedPosition = Duration.zero;
  String? _restoredAccountKey;
  bool _restoring = false;
  bool _disposed = false;

  void _handleConnection(JellyfinConnectionState connection) {
    if (connection.isConnected) {
      unawaited(_restore());
    } else {
      _restoredAccountKey = null;
    }
  }

  void _handlePlayback(PlaybackSnapshot playback) {
    final movedEnough =
        (playback.position - _lastSavedPosition).abs() >=
        _positionWriteInterval;
    final importantState = switch (playback.status) {
      PlaybackStatus.ready ||
      PlaybackStatus.paused ||
      PlaybackStatus.stopped ||
      PlaybackStatus.completed ||
      PlaybackStatus.error => true,
      _ => false,
    };
    if (movedEnough || importantState) {
      _scheduleSave();
    }
  }

  Future<void> _restore() async {
    if (isFollowingParty?.call() == true) return;
    final connection = _connectionController.state;
    final serverId = connection.serverInfo?.id;
    final userId = connection.session?.userId;
    if (!connection.isConnected || serverId == null || userId == null) {
      return;
    }
    final accountKey = '$serverId:$userId';
    if (_restoredAccountKey == accountKey || _restoring) {
      return;
    }
    _restoring = true;
    try {
      final saved = await _store.read();
      if (isFollowingParty?.call() == true) return;
      _restoredAccountKey = accountKey;
      if (saved == null ||
          saved.serverId != serverId ||
          saved.userId != userId) {
        return;
      }
      final sources = saved.items.indexed
          .map((entry) {
            final (index, item) = entry;
            final stream = _connectionController.createDirectPlaySource(
              item.itemId,
            );
            return RemotePlaybackSource(
              uri: stream.uri,
              headers: stream.headers,
              title: item.title,
              artist: item.artist,
              itemId: item.itemId,
              artworkBytes: index == saved.currentIndex
                  ? saved.artworkBytes
                  : null,
              artworkId: item.artworkId ?? item.itemId,
              artworkTag: item.artworkTag,
              startPosition: index == saved.currentIndex
                  ? saved.position
                  : Duration.zero,
            );
          })
          .toList(growable: false);
      await _queueController.restore(
        sources,
        currentIndex: saved.currentIndex,
        volume: saved.volume,
        shuffleEnabled: saved.shuffleEnabled,
        repeatMode: saved.repeatMode,
        originalOrder: saved.originalOrder,
      );
      _lastSavedPosition = saved.position;
    } catch (_) {
      // Restoration is a convenience. A damaged or stale snapshot must never
      // prevent connection, library browsing, or new playback.
    } finally {
      _restoring = false;
    }
  }

  void _scheduleSave() {
    if (_disposed || _restoring) {
      return;
    }
    _pending = _pending.then((_) => _save()).catchError((_) {});
  }

  Future<void> _save() async {
    if (isFollowingParty?.call() == true) return;
    final connection = _connectionController.state;
    final serverId = connection.serverInfo?.id;
    final userId = connection.session?.userId;
    final queue = _queueController.state;
    if (!connection.isConnected ||
        serverId == null ||
        userId == null ||
        queue.items.isEmpty ||
        queue.currentIndex < 0) {
      return;
    }
    final items = <StoredQueueItem>[];
    for (final source in queue.items) {
      final itemId = source.itemId;
      if (itemId == null || itemId.isEmpty) {
        return;
      }
      items.add(
        StoredQueueItem(
          itemId: itemId,
          title: source.title,
          artist: source.artist,
          artworkId: source.artworkId,
          artworkTag: source.artworkTag,
        ),
      );
    }
    final playback = _playbackController.state;
    final currentItemId = queue.items[queue.currentIndex].itemId;
    final position = playback.itemId == currentItemId
        ? playback.position
        : Duration.zero;
    await _store.write(
      StoredPlaybackState(
        serverId: serverId,
        userId: userId,
        items: items,
        currentIndex: queue.currentIndex,
        position: position,
        volume: playback.volume,
        shuffleEnabled: queue.shuffleEnabled,
        repeatMode: queue.repeatMode,
        originalOrder: queue.originalOrder,
        artworkBytes: queue.items[queue.currentIndex].artworkBytes,
      ),
    );
    _lastSavedPosition = position;
  }

  /// Persist the last position before an explicit desktop Quit action.
  Future<void> flush() async {
    if (_disposed || _restoring) return;
    _pending = _pending.then((_) => _save()).catchError((_) {});
    await _pending;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _queueSubscription.cancel();
    await _playbackSubscription.cancel();
    await _connectionSubscription.cancel();
    await _pending;
    await _store.close();
  }
}
