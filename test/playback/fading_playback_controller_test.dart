import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/playback/fading_playback_controller.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';

void main() {
  late EnvelopeTestBackend backend;
  late FadingPlaybackController player;
  late List<Duration> delays;
  late List<PlaybackSnapshot> snapshots;
  late StreamSubscription<PlaybackSnapshot> subscription;
  Future<void> Function()? onDelay;

  setUp(() {
    backend = EnvelopeTestBackend();
    delays = [];
    snapshots = [];
    onDelay = null;
    player = FadingPlaybackController(
      backend,
      delay: (duration) async {
        delays.add(duration);
        await onDelay?.call();
      },
    );
    subscription = player.states.listen(snapshots.add);
  });
  tearDown(() async {
    await subscription.cancel();
    await player.dispose();
  });
  Future<void> ready() => player.loadRemoteSource(source('One'));
  List<double> volumes() => backend.actions
      .where((action) => action.$1 == 'volume')
      .map((action) => action.$2)
      .toList();
  Duration elapsed() => delays.fold(Duration.zero, (a, b) => a + b);
  void monotonic(List<double> values, {required bool increasing}) {
    expect(values.length, greaterThan(3));
    for (var i = 1; i < values.length; i++) {
      expect(
        increasing ? values[i] >= values[i - 1] : values[i] <= values[i - 1],
        isTrue,
      );
    }
  }

  test(
    'resume starts silent, fades smoothly, and keeps public volume steady',
    () async {
      await ready();
      backend.actions.clear();
      await player.play();
      monotonic(volumes(), increasing: true);
      expect(volumes().first, 0);
      expect(volumes().last, closeTo(0.6, 0.000001));
      expect(backend.actions.firstWhere((a) => a.$1 == 'play').$2, 0);
      expect(elapsed(), FadingPlaybackController.fadeIn);
      expect(snapshots.every((s) => s.volume == 0.6), isTrue);
      expect(player.state.status, PlaybackStatus.playing);
      expect(player.state.volume, 0.6);
    },
  );

  test(
    'pause and stop only reach the backend after fading to silence',
    () async {
      await ready();
      await player.play();
      backend.actions.clear();
      delays.clear();
      await player.pause();
      monotonic(volumes(), increasing: false);
      expect(backend.actions.last, ('pause', 0.0));
      expect(elapsed(), FadingPlaybackController.fadeOut);
      expect(player.state.status, PlaybackStatus.paused);
      expect(player.state.volume, 0.6);
      await player.play();
      backend.actions.clear();
      await player.stop();
      expect(backend.actions.last, ('stop', 0.0));
      expect(player.state.status, PlaybackStatus.stopped);
    },
  );

  test(
    'next and previous soften both edges, paused navigation stays silent',
    () async {
      final queue = PlaybackQueueController(playbackController: player);
      addTearDown(queue.dispose);
      await queue.playAlbum([source('One'), source('Two')], startIndex: 0);
      backend.actions.clear();
      delays.clear();
      await queue.next();
      expect(backend.actions.firstWhere((a) => a.$1 == 'load:Two').$2, 0);
      expect(backend.actions.firstWhere((a) => a.$1 == 'play').$2, 0);
      expect(volumes().last, closeTo(0.6, 0.000001));
      expect(
        elapsed(),
        FadingPlaybackController.trackFadeOut + FadingPlaybackController.fadeIn,
      );
      await player.pause();
      backend.actions.clear();
      await queue.previous(play: false);
      expect(player.state.title, 'One');
      expect(player.state.status, PlaybackStatus.ready);
      expect(backend.actions.any((a) => a.$1 == 'play'), isFalse);
      expect(backend.state.volume, 0);
      expect(player.state.volume, 0.6);
    },
  );

  test(
    'volume changes during a fade use the latest setting without a jump',
    () async {
      await ready();
      var count = 0;
      onDelay = () async {
        if (++count == 3) await player.setVolume(0.25);
      };
      await player.play();
      expect(backend.state.volume, 0.25);
      expect(player.state.volume, 0.25);
      expect(
        snapshots.every((s) => s.volume == 0.6 || s.volume == 0.25),
        isTrue,
      );
      await player.pause();
      await player.setVolume(0.8);
      expect(backend.state.volume, 0);
      expect(player.state.volume, 0.8);
      await player.play();
      expect(backend.state.volume, 0.8);
    },
  );

  test('muted playback stays muted across transitions without delay', () async {
    await ready();
    await player.setVolume(0);
    await player.play();
    await player.pause();
    await player.loadRemoteSource(source('Two'));
    await player.play();
    expect(delays, isEmpty);
    expect(backend.state.volume, 0);
    expect(player.state.volume, 0);
  });

  test(
    'playing seek dips and recovers; queued scrubs use the latest target',
    () async {
      await ready();
      await player.play();
      backend.actions.clear();
      delays.clear();
      await Future.wait([
        player.seek(const Duration(seconds: 2)),
        player.seek(const Duration(seconds: 4)),
        player.seek(const Duration(seconds: 8)),
      ]);
      expect(backend.seekPositions, [const Duration(seconds: 8)]);
      expect(backend.actions.firstWhere((a) => a.$1 == 'seek').$2, 0);
      expect(
        elapsed(),
        FadingPlaybackController.seekFadeOut +
            FadingPlaybackController.seekFadeIn,
      );
      expect(backend.state.volume, 0.6);
      await player.pause();
      backend.actions.clear();
      delays.clear();
      await player.seek(const Duration(seconds: 3));
      expect(delays, isEmpty);
      expect(player.state.status, PlaybackStatus.paused);
      expect(backend.actions.any((a) => a.$1 == 'play'), isFalse);
    },
  );

  test(
    'rapid alternating commands finish at the requested state and volume',
    () async {
      await ready();
      await Future.wait([
        player.play(),
        player.pause(),
        player.play(),
        player.pause(),
        player.play(),
      ]);
      expect(player.state.status, PlaybackStatus.playing);
      expect(backend.state.volume, 0.6);
      expect(
        backend.actions
            .where((a) => a.$1 == 'play' || a.$1 == 'pause')
            .map((a) => a.$1),
        ['play', 'pause', 'play', 'pause', 'play'],
      );
    },
  );

  test(
    'backend failure restores audible gain and later controls still work',
    () async {
      await ready();
      await player.play();
      backend.failPause = true;
      await expectLater(player.pause(), throwsStateError);
      expect(backend.state.volume, 0.6);
      expect(player.state.volume, 0.6);
      await player.pause();
      await player.play();
      expect(backend.state.volume, 0.6);
    },
  );

  test(
    'disposing mid-fade cancels remaining volume writes and commands',
    () async {
      await ready();
      final entered = Completer<void>();
      final release = Completer<void>();
      onDelay = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final playing = player.play();
      await entered.future;
      final disposing = player.dispose();
      final actionCount = backend.actions.length;
      release.complete();
      await playing;
      await disposing;
      expect(backend.actions.length, actionCount);
      expect(backend.disposed, isTrue);
      await player.setVolume(1);
      await player.play();
      expect(backend.actions.length, actionCount);
    },
  );

  test('fade volume events do not spam public playback state', () async {
    await ready();
    snapshots.clear();
    await player.play();
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.length, lessThan(4));
    expect(snapshots.every((s) => s.volume == 0.6), isTrue);
    await player.setVolume(0.4);
    expect(player.state.volume, 0.4);
  });
}

RemotePlaybackSource source(String title) => RemotePlaybackSource(
  uri: Uri.parse('https://music.example/$title'),
  title: title,
  artist: 'Artist',
  itemId: title,
);

class EnvelopeTestBackend implements PlaybackController {
  final actions = <(String, double)>[];
  final seekPositions = <Duration>[];
  final _states = StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot _state = const PlaybackSnapshot(volume: 0.6);
  bool failPause = false;
  bool disposed = false;
  @override
  PlaybackSnapshot get state => _state;
  @override
  Stream<PlaybackSnapshot> get states => _states.stream;
  void emit(PlaybackSnapshot value) {
    _state = value;
    _states.add(value);
  }

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) async {
    actions.add(('load:${source.title}', _state.volume));
    emit(
      PlaybackSnapshot(
        status: PlaybackStatus.ready,
        volume: _state.volume,
        title: source.title,
        artist: source.artist,
        sourceLabel: source.title,
        itemId: source.itemId,
        duration: const Duration(minutes: 3),
      ),
    );
  }

  @override
  Future<void> loadLocalFile(String path) => loadRemoteSource(source(path));
  @override
  Future<void> loadRemoteUrl(Uri url) => loadRemoteSource(source('Remote'));
  @override
  Future<void> play() async {
    actions.add(('play', _state.volume));
    emit(_state.copyWith(status: PlaybackStatus.playing));
  }

  @override
  Future<void> pause() async {
    actions.add(('pause', _state.volume));
    if (failPause) {
      failPause = false;
      throw StateError('Simulated failure');
    }
    emit(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> stop() async {
    actions.add(('stop', _state.volume));
    emit(_state.copyWith(status: PlaybackStatus.stopped));
  }

  @override
  Future<void> seek(Duration position) async {
    seekPositions.add(position);
    actions.add(('seek', _state.volume));
    emit(_state.copyWith(position: position));
  }

  @override
  Future<void> setVolume(double volume) async {
    actions.add(('volume', volume));
    emit(_state.copyWith(volume: volume));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _states.close();
  }
}
