import 'dart:async';
import 'dart:math';

import 'playback_controller.dart';

enum PlaybackRepeatMode { off, all, one }

class PlaybackQueueState {
  const PlaybackQueueState({
    this.items = const [],
    this.currentIndex = -1,
    this.shuffleEnabled = false,
    this.repeatMode = PlaybackRepeatMode.off,
    this.originalOrder = const [],
  });

  final List<RemotePlaybackSource> items;
  final int currentIndex;
  final bool shuffleEnabled;
  final PlaybackRepeatMode repeatMode;

  /// Positions in [items], listed in their unshuffled order. Queue slots remain
  /// distinct even when the same song (or source object) occurs more than once.
  final List<int> originalOrder;

  bool get hasPrevious => currentIndex > 0 || _loops;
  bool get hasNext =>
      currentIndex >= 0 && (currentIndex + 1 < items.length || _loops);
  bool get _loops =>
      currentIndex >= 0 &&
      items.isNotEmpty &&
      repeatMode == PlaybackRepeatMode.all;
}

class _QueueEntry {
  _QueueEntry(this.source);
  final RemotePlaybackSource source;
}

class PlaybackQueueController {
  PlaybackQueueController({
    required PlaybackController playbackController,
    Random? random,
  }) : _playbackController = playbackController,
       _random = random ?? Random() {
    _playbackSubscription = playbackController.states.listen((playback) {
      if (playback.completed && !_completionHandled) {
        _completionHandled = true;
        unawaited(_complete());
      } else if (!playback.completed) {
        _completionHandled = false;
      }
    });
  }

  final PlaybackController _playbackController;
  final Random _random;
  final StreamController<PlaybackQueueState> _states =
      StreamController<PlaybackQueueState>.broadcast();
  late final StreamSubscription<PlaybackSnapshot> _playbackSubscription;
  PlaybackQueueState _state = const PlaybackQueueState();
  final List<_QueueEntry> _items = [];
  final List<_QueueEntry> _originalItems = [];
  int _currentIndex = -1;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  bool _completionHandled = false;

  static const previousRestartThreshold = Duration(seconds: 5);

  PlaybackQueueState get state => _state;
  Stream<PlaybackQueueState> get states => _states.stream;

  bool followingParty = false;
  Future<void> Function(String, Map<String, dynamic>)? partyCommand;

  /// A follower mirrors the host order without starting local queue playback.
  void updatePartyQueue(
    List<RemotePlaybackSource> items,
    int index, {
    bool preserveModes = false,
  }) {
    _replaceItems(items);
    _currentIndex = index;
    if (!preserveModes) {
      _shuffleEnabled = false;
      _repeatMode = PlaybackRepeatMode.off;
    }
    _publish();
  }

  void setShuffle(bool enabled) {
    if (followingParty) return;
    if (_shuffleEnabled == enabled) return;
    _shuffleEnabled = enabled;
    final upcoming = _items.sublist(_currentIndex + 1);
    if (enabled) {
      upcoming.shuffle(_random);
    } else {
      final order = {for (final (i, entry) in _originalItems.indexed) entry: i};
      upcoming.sort((a, b) => order[a]!.compareTo(order[b]!));
    }
    _items.replaceRange(_currentIndex + 1, _items.length, upcoming);
    _publish();
  }

  void setRepeatMode(PlaybackRepeatMode mode) {
    if (followingParty) return;
    if (_repeatMode == mode) return;
    _repeatMode = mode;
    _publish();
  }

  void cycleRepeatMode() => setRepeatMode(
    PlaybackRepeatMode.values[(_repeatMode.index + 1) %
        PlaybackRepeatMode.values.length],
  );

  void _replaceItems(List<RemotePlaybackSource> items) {
    _items
      ..clear()
      ..addAll(items.map(_QueueEntry.new));
    _originalItems
      ..clear()
      ..addAll(_items);
  }

  /// Starting a collection respects shuffle; selecting a row stays explicit.
  Future<void> playCollection(List<RemotePlaybackSource> items) async {
    if (followingParty || items.isEmpty) return;
    await playAlbum(
      items,
      startIndex: _shuffleEnabled ? _random.nextInt(items.length) : 0,
    );
  }

  Future<void> playAlbum(
    List<RemotePlaybackSource> items, {
    required int startIndex,
  }) async {
    if (followingParty ||
        items.isEmpty ||
        startIndex < 0 ||
        startIndex >= items.length)
      return;
    _replaceItems(items);
    _currentIndex = startIndex;
    if (_shuffleEnabled) {
      final selected = _items.removeAt(startIndex);
      _items.shuffle(_random);
      _items.insert(0, selected);
      _currentIndex = 0;
    }
    _publish();
    await _openCurrent();
  }

  Future<void> restore(
    List<RemotePlaybackSource> items, {
    required int currentIndex,
    required double volume,
    bool shuffleEnabled = false,
    PlaybackRepeatMode repeatMode = PlaybackRepeatMode.off,
    List<int> originalOrder = const [],
  }) async {
    if (followingParty ||
        items.isEmpty ||
        currentIndex < 0 ||
        currentIndex >= items.length)
      return;
    _replaceItems(items);
    if (originalOrder.length == items.length &&
        originalOrder.toSet().length == items.length &&
        originalOrder.every((i) => i >= 0 && i < items.length)) {
      _originalItems
        ..clear()
        ..addAll(originalOrder.map((i) => _items[i]));
    }
    _currentIndex = currentIndex;
    _shuffleEnabled = shuffleEnabled;
    _repeatMode = repeatMode;
    _publish();
    await _playbackController.loadRemoteSource(items[currentIndex]);
    await _playbackController.setVolume(volume.clamp(0, 1));
  }

  Future<void> enqueue(
    List<RemotePlaybackSource> items, {
    bool next = false,
  }) async {
    if (followingParty || items.isEmpty) return;
    if (_items.isEmpty) {
      _replaceItems(items);
      if (_shuffleEnabled) _items.shuffle(_random);
      _currentIndex = 0;
      _publish();
      await _playbackController.loadRemoteSource(
        _fromBeginning(_items.first.source),
      );
      return;
    }
    final added = items.map(_QueueEntry.new).toList();
    _originalItems.insertAll(
      next
          ? _originalItems.indexOf(_items[_currentIndex]) + 1
          : _originalItems.length,
      added,
    );
    _items.insertAll(next ? _currentIndex + 1 : _items.length, added);
    _publish();
  }

  Future<void> playAt(int index) async {
    if (followingParty) {
      await partyCommand?.call('playAt', {'index': index});
      return;
    }
    if (index < 0 || index >= _items.length) return;
    _currentIndex = index;
    _publish();
    await _openCurrent();
  }

  void removeAt(int index) {
    if (followingParty) {
      unawaited(partyCommand?.call('remove', {'index': index}));
      return;
    }
    if (index < 0 || index >= _items.length || index == _currentIndex) return;
    _originalItems.remove(_items.removeAt(index));
    if (index < _currentIndex) _currentIndex--;
    _publish();
  }

  void moveUpcoming(int oldIndex, int newIndex) {
    if (followingParty) {
      unawaited(
        partyCommand?.call('move', {'index': oldIndex, 'to': newIndex}),
      );
      return;
    }
    if (oldIndex <= _currentIndex ||
        newIndex <= _currentIndex ||
        oldIndex >= _items.length ||
        newIndex >= _items.length)
      return;
    final entry = _items.removeAt(oldIndex);
    _items.insert(newIndex, entry);
    _originalItems.remove(entry);
    _originalItems.insert(
      newIndex + 1 < _items.length
          ? _originalItems.indexOf(_items[newIndex + 1])
          : _originalItems.length,
      entry,
    );
    _publish();
  }

  void clearUpcoming() {
    if (followingParty) {
      unawaited(partyCommand?.call('clear', {}));
      return;
    }
    if (_currentIndex + 1 >= _items.length) return;
    final removed = _items.sublist(_currentIndex + 1).toSet();
    _items.removeRange(_currentIndex + 1, _items.length);
    _originalItems.removeWhere(removed.contains);
    _publish();
  }

  Future<void> previous({bool play = true}) async {
    if (followingParty) {
      await partyCommand?.call('previous', {});
      return;
    }
    if (_playbackController.state.position > previousRestartThreshold) {
      await _playbackController.seek(Duration.zero);
      return;
    }
    if (!_state.hasPrevious) return;
    _currentIndex = _currentIndex > 0 ? _currentIndex - 1 : _items.length - 1;
    _publish();
    await _openCurrent(play: play);
  }

  Future<void> next({bool play = true}) async {
    if (followingParty) {
      await partyCommand?.call('next', {});
      return;
    }
    if (!_state.hasNext) return;
    if (_currentIndex + 1 < _items.length) {
      _currentIndex++;
    } else {
      final previous = _items[_currentIndex];
      if (_shuffleEnabled && _items.length > 1) {
        _items.shuffle(_random);
        // Avoid an immediate repeat across two shuffled queue passes.
        if (identical(_items.first, previous)) {
          _items[0] = _items[1];
          _items[1] = previous;
        }
      }
      _currentIndex = 0;
    }
    _publish();
    await _openCurrent(play: play);
  }

  Future<void> _complete() async {
    if (followingParty) return;
    if (_items.isEmpty) return;
    if (_repeatMode == PlaybackRepeatMode.one) {
      await _openCurrent();
    } else {
      await next();
    }
  }

  Future<void> _openCurrent({bool play = true}) async {
    await _playbackController.loadRemoteSource(
      _fromBeginning(_items[_currentIndex].source),
    );
    if (play) await _playbackController.play();
  }

  RemotePlaybackSource _fromBeginning(RemotePlaybackSource source) =>
      RemotePlaybackSource(
        uri: source.uri,
        headers: source.headers,
        title: source.title,
        artist: source.artist,
        itemId: source.itemId,
        artworkBytes: source.artworkBytes,
        artworkId: source.artworkId,
        artworkTag: source.artworkTag,
      );

  void _publish() {
    final positions = {for (final (i, entry) in _items.indexed) entry: i};
    _state = PlaybackQueueState(
      items: List.unmodifiable(_items.map((entry) => entry.source)),
      currentIndex: _currentIndex,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
      originalOrder: List.unmodifiable(
        _originalItems.map((entry) => positions[entry]!),
      ),
    );
    if (!_states.isClosed) _states.add(_state);
  }

  Future<void> dispose() async {
    await _playbackSubscription.cancel();
    await _states.close();
  }
}
