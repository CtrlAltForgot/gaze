import 'dart:typed_data';

class StoredQueueItem {
  const StoredQueueItem({
    required this.itemId,
    required this.title,
    required this.artist,
  });

  final String itemId;
  final String title;
  final String artist;
}

class StoredPlaybackState {
  const StoredPlaybackState({
    required this.serverId,
    required this.userId,
    required this.items,
    required this.currentIndex,
    required this.position,
    required this.volume,
    this.artworkBytes,
  });

  final String serverId;
  final String userId;
  final List<StoredQueueItem> items;
  final int currentIndex;
  final Duration position;
  final double volume;
  final Uint8List? artworkBytes;
}

abstract interface class PlaybackStateStore {
  Future<StoredPlaybackState?> read();

  Future<void> write(StoredPlaybackState state);

  Future<void> clear();

  Future<void> close();
}

class DisabledPlaybackStateStore implements PlaybackStateStore {
  const DisabledPlaybackStateStore();

  @override
  Future<StoredPlaybackState?> read() async => null;

  @override
  Future<void> write(StoredPlaybackState state) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> close() async {}
}
