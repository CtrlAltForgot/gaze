@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/linux_media_session.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';

void main() {
  late DBusServer server;
  late Directory directory;
  late DBusAddress address;
  late DBusClient client;
  late LinuxMediaSession session;
  late DBusRemoteObject remote;
  late MediaKeyTestPlayback playback;
  late PlaybackQueueController queue;
  const player = LinuxMediaSession.playerInterface;

  Future<void> command(String name, [List<DBusValue> values = const []]) async {
    await remote.callMethod(
      player,
      name,
      values,
      replySignature: DBusSignature(''),
    );
  }

  Future<DBusValue> property(String name) => remote.getProperty(player, name);
  Future<void> load() => queue.playAlbum([
    for (final title in ['One', 'Two', 'Three'])
      RemotePlaybackSource(
        uri: Uri.parse('https://private.invalid/$title'),
        title: title,
        artist: 'Artist',
        itemId: title,
        headers: {'Authorization': 'secret-never-exported'},
      ),
  ], startIndex: 0);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gaze-media-test-');
    server = DBusServer();
    address = await server.listenAddress(
      DBusAddress.unix(path: '${directory.path}/bus'),
    );
    playback = MediaKeyTestPlayback();
    queue = PlaybackQueueController(playbackController: playback);
    session = LinuxMediaSession(
      playback: playback,
      queue: queue,
      bus: DBusClient(address),
    );
    await session.start();
    client = DBusClient(address);
    remote = DBusRemoteObject(
      client,
      name: session.busName,
      path: session.path,
    );
  });
  tearDown(() async {
    await session.dispose();
    await client.close();
    await queue.dispose();
    await playback.dispose();
    await server.close();
    await directory.delete(recursive: true);
  });

  test(
    'exports discoverable MPRIS properties and ignores empty transport',
    () async {
      final node = await remote.introspect();
      expect(node.interfaces.map((i) => i.name), contains(player));
      expect(
        (await remote.getProperty(
          LinuxMediaSession.rootInterface,
          'Identity',
        )).asString(),
        'gaze',
      );
      expect((await property('CanPlay')).asBoolean(), isFalse);
      for (final name in [
        'PlayPause',
        'Play',
        'Pause',
        'Stop',
        'Next',
        'Previous',
      ]) {
        await command(name);
      }
      expect(playback.commands, isEmpty);
    },
  );

  test(
    'background bus transport reaches playback and queue in order',
    () async {
      await load();
      expect((await property('PlaybackStatus')).asString(), 'Playing');
      await command('PlayPause');
      expect(playback.state.status, PlaybackStatus.paused);
      await command('PlayPause');
      expect(playback.state.status, PlaybackStatus.playing);
      await Future.wait([command('Next'), command('Next')]);
      expect(queue.state.currentIndex, 2);
      expect(playback.state.title, 'Three');
      expect((await property('CanGoNext')).asBoolean(), isFalse);
      await command('Next');
      expect(queue.state.currentIndex, 2);
      await command('Previous');
      expect(playback.state.title, 'Two');
      await command('Stop');
      expect((await property('PlaybackStatus')).asString(), 'Stopped');
      await command('Play');
      expect(playback.state.status, PlaybackStatus.playing);
      expect(playback.state.title, 'Two');
    },
  );

  test('skip stays paused and previous restarts after five seconds', () async {
    await load();
    await command('Pause');
    final playCount = playback.commands.where((c) => c == 'play').length;
    await command('Next');
    expect(playback.state.title, 'Two');
    expect((await property('PlaybackStatus')).asString(), 'Paused');
    expect(playback.commands.where((c) => c == 'play').length, playCount);
    await playback.seek(const Duration(seconds: 6));
    await command('Previous');
    expect(playback.state.position, Duration.zero);
    expect(queue.state.currentIndex, 1);
    await command('Previous');
    expect(queue.state.currentIndex, 0);
  });

  test('metadata is safe and stale or out-of-range seek is ignored', () async {
    await load();
    final metadata = (await property('Metadata')).asStringVariantDict();
    expect(metadata['xesam:title']!.asString(), 'One');
    expect(metadata.toString(), isNot(contains('secret')));
    expect(metadata.toString(), isNot(contains('private.invalid')));
    final trackId = metadata['mpris:trackid']!;
    await command('SetPosition', [trackId, const DBusInt64(4000000)]);
    expect(playback.state.position, const Duration(seconds: 4));
    await command('SetPosition', [trackId, const DBusInt64(-1)]);
    await command('SetPosition', [trackId, const DBusInt64(900000000)]);
    expect(playback.state.position, const Duration(seconds: 4));
    await command('Next');
    await command('SetPosition', [trackId, const DBusInt64(4000000)]);
    expect(playback.state.position, Duration.zero);
    await command('Seek', [const DBusInt64(-4000000)]);
    expect(playback.state.position, Duration.zero);
    await command('Seek', [const DBusInt64(900000000)]);
    expect(playback.state.title, 'Three');
  });

  test(
    'volume clamps, invalid arguments fail, and later commands still work',
    () async {
      await remote.setProperty(player, 'Volume', const DBusDouble(-1));
      expect(playback.state.volume, 0);
      await remote.setProperty(player, 'Volume', const DBusDouble(3));
      expect(playback.state.volume, 1);
      await expectLater(
        command('Seek', [const DBusString('bad')]),
        throwsA(isA<DBusInvalidArgsException>()),
      );
      await load();
      await command('Pause');
      expect(playback.state.status, PlaybackStatus.paused);
    },
  );

  test(
    'publishes state changes but not progress ticks as property changes',
    () async {
      final signals = <DBusPropertiesChangedSignal>[];
      final subscription = remote.propertiesChanged.listen(signals.add);
      await client.ping();
      await load();
      await command('Pause');
      await command('Play');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        signals.any(
          (s) =>
              s.changedProperties['PlaybackStatus'] ==
              const DBusString('Paused'),
        ),
        isTrue,
      );
      expect(
        signals.any((s) => s.changedProperties.containsKey('Metadata')),
        isTrue,
      );
      signals.clear();
      await playback.seek(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        signals.any((s) => s.changedProperties.containsKey('Position')),
        isFalse,
      );
      await subscription.cancel();
    },
  );

  test(
    'second instance cannot steal controls and disposal releases the name',
    () async {
      final second = LinuxMediaSession(
        playback: playback,
        queue: queue,
        bus: DBusClient(address),
      );
      await expectLater(second.start(), throwsStateError);
      await second.dispose();
      await load();
      await command('Pause');
      expect(playback.state.status, PlaybackStatus.paused);
      await session.dispose();
      final replacement = LinuxMediaSession(
        playback: playback,
        queue: queue,
        bus: DBusClient(address),
      );
      await replacement.start();
      await replacement.dispose();
    },
  );

  test(
    'shuffle and repeat synchronize both ways and reject malformed modes',
    () async {
      await load();
      await command('Pause');
      final original = playback.state.title;
      await remote.setProperty(player, 'Shuffle', const DBusBoolean(true));
      await remote.setProperty(player, 'LoopStatus', const DBusString('Track'));
      expect(queue.state.shuffleEnabled, isTrue);
      expect(queue.state.repeatMode, PlaybackRepeatMode.one);
      expect(playback.state.title, original);
      expect(playback.state.status, PlaybackStatus.paused);
      queue.setRepeatMode(PlaybackRepeatMode.all);
      queue.setShuffle(false);
      expect((await property('LoopStatus')).asString(), 'Playlist');
      expect((await property('Shuffle')).asBoolean(), isFalse);
      await queue.playAt(2);
      expect((await property('CanGoNext')).asBoolean(), isTrue);
      await expectLater(
        remote.setProperty(player, 'LoopStatus', const DBusString('bad')),
        throwsA(isA<DBusInvalidArgsException>()),
      );
      await expectLater(
        remote.setProperty(player, 'Shuffle', const DBusString('true')),
        throwsA(isA<DBusInvalidArgsException>()),
      );
      expect(queue.state.repeatMode, PlaybackRepeatMode.all);
    },
  );

  test('unavailable bus fails without changing playback', () async {
    final unavailable = LinuxMediaSession(
      playback: playback,
      queue: queue,
      bus: DBusClient(DBusAddress.unix(path: '${directory.path}/missing')),
    );
    await expectLater(unavailable.start(), throwsA(isA<SocketException>()));
    await unavailable.dispose();
    expect(playback.commands, isEmpty);
  });
}

class MediaKeyTestPlayback implements PlaybackController {
  final _states = StreamController<PlaybackSnapshot>.broadcast();
  final commands = <String>[];
  PlaybackSnapshot _state = const PlaybackSnapshot();
  @override
  PlaybackSnapshot get state => _state;
  @override
  Stream<PlaybackSnapshot> get states => _states.stream;
  void emit(PlaybackSnapshot state) {
    _state = state;
    _states.add(state);
  }

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) async {
    commands.add('load:${source.title}');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    emit(
      PlaybackSnapshot(
        status: PlaybackStatus.ready,
        title: source.title,
        sourceLabel: source.title,
        artist: source.artist,
        itemId: source.itemId,
        duration: const Duration(minutes: 3),
        volume: _state.volume,
      ),
    );
  }

  @override
  Future<void> play() async {
    commands.add('play');
    emit(_state.copyWith(status: PlaybackStatus.playing));
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    emit(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    emit(
      _state.copyWith(status: PlaybackStatus.stopped, position: Duration.zero),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    commands.add('seek');
    emit(_state.copyWith(position: position));
  }

  @override
  Future<void> setVolume(double volume) async {
    emit(_state.copyWith(volume: volume));
  }

  @override
  Future<void> loadLocalFile(String path) async {}
  @override
  Future<void> loadRemoteUrl(Uri uri) async {}
  @override
  Future<void> dispose() => _states.close();
}
