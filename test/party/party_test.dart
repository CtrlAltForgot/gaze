import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/party/party_api.dart';
import 'package:gaze/party/party_controller.dart';
import 'package:gaze/party/party_playback_controller.dart';
import 'package:gaze/connect/connect_controller.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import '../widget_test.dart' as fixtures;
import '../desktop/connect_workflows_test.dart' show Preferences, Service;

class Player extends fixtures.FakePlaybackController {
  PlaybackSnapshot current = const PlaybackSnapshot();
  final events = StreamController<PlaybackSnapshot>.broadcast();
  int loads = 0;
  @override
  PlaybackSnapshot get state => current;
  @override
  Stream<PlaybackSnapshot> get states => events.stream;
  void update(PlaybackSnapshot value) {
    current = value;
    events.add(value);
  }

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) async {
    loads++;
    loadedRemoteSource = source;
    update(
      PlaybackSnapshot(
        status: PlaybackStatus.ready,
        title: source.title,
        artist: source.artist,
        itemId: source.itemId,
      ),
    );
  }

  @override
  Future<void> pause() async =>
      update(current.copyWith(status: PlaybackStatus.paused));
  @override
  Future<void> play() async =>
      update(current.copyWith(status: PlaybackStatus.playing));
  @override
  Future<void> stop() async =>
      update(const PlaybackSnapshot(status: PlaybackStatus.stopped));
  @override
  Future<void> seek(Duration position) async {
    soughtPosition = position;
    update(current.copyWith(position: position));
  }

  @override
  Future<void> setVolume(double volume) async =>
      update(current.copyWith(volume: volume));
  @override
  Future<void> dispose() async {
    await events.close();
    await super.dispose();
  }
}

class Api implements PartyApi {
  Map<String, dynamic> data = {
    'id': 'a' * 32,
    'token': 'guest-token',
    'hostName': 'Host',
    'revision': 1,
    'index': 0,
    'playing': true,
    'connected': true,
    'serverTime': 2000,
    'updatedAt': 1000,
    'positionMs': 4000,
    'listeners': ['Guest'],
    'queue': [
      {
        'id': 'b' * 32,
        'slot': 'first',
        'title': 'Shared song',
        'artist': 'Artist',
        'durationMs': 180000,
        'hasArtwork': false,
      },
      {
        'id': 'c' * 32,
        'slot': 'second',
        'title': 'Next song',
        'artist': 'Artist',
        'durationMs': 180000,
        'hasArtwork': false,
      },
    ],
  };
  final calls = <String>[];
  final bodies = <Map<String, dynamic>?>[];
  PartyException? failure;
  @override
  Future<Map<String, dynamic>> request(
    Uri server,
    String token,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add(path);
    bodies.add(body);
    if (failure != null) throw failure!;
    return {...data};
  }

  @override
  Future<Uint8List?> artwork(Uri uri, String token) async => null;
  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'invitation parser accepts HTTPS and native links but rejects ambiguous origins',
    () {
      final id = 'a' * 32, secret = 'b' * 43;
      final https = PartyInvite.parse(
        'https://music.example/party/$id#$secret',
      );
      final native = PartyInvite.parse(
        'gaze://party/$id?server=https%3A%2F%2Fmusic.example#$secret',
      );
      expect(native.server, https.server);
      expect(native.id, id);
      final short = PartyInvite.parse(
        'https://music.example/party/9a2jjgf4kr8m',
      );
      expect(short.isShort, true);
      expect(
        PartyInvite.parse(
          'gaze://party/9a2jjgf4kr8m?server=https%3A%2F%2Fmusic.example',
        ).id,
        short.id,
      );
      for (final link in [
        'http://music.example/party/$id#$secret',
        'https://user:password@music.example/party/$id#$secret',
        'gaze://party/$id?server=https%3A%2F%2Fmusic.example%2Fprivate#$secret',
        'https://music.example/party/$id#short',
        'https://music.example/party/$id?redirect=bad#$secret',
      ]) {
        expect(() => PartyInvite.parse(link), throwsA(isA<PartyException>()));
      }
    },
  );
  test(
    'guest follows host seek/pause/track, keeps volume, blocks transport and restores own queue',
    () async {
      final player = Player();
      PartyController? party;
      final guarded = PartyPlaybackController(
        player,
        () => party?.following == true,
      );
      final queue = PlaybackQueueController(playbackController: guarded);
      final connection = JellyfinConnectionController(
        apiFactory: (_) => fixtures.FakeJellyfinApi(),
        credentialStore: fixtures.FakeCredentialStore(),
      );
      final connect = ConnectController(
        connection: connection,
        api: Service(),
        preferences: Preferences(),
      );
      final api = Api();
      party = PartyController(
        api: api,
        connect: connect,
        playback: player,
        queue: queue,
      );
      addTearDown(() async {
        party!.dispose();
        connect.dispose();
        await queue.dispose();
        await player.dispose();
        await connection.dispose();
      });
      await queue.playAlbum([
        RemotePlaybackSource(
          uri: Uri.parse('https://own.example/song'),
          title: 'My song',
          artist: 'Mine',
          itemId: 'own',
        ),
      ], startIndex: 0);
      await player.seek(const Duration(seconds: 42));
      await party.join(
        PartyInvite(Uri.parse('https://music.example'), 'a' * 32, 'b' * 43),
        'Guest',
      );
      expect(party.following, true);
      expect(player.state.title, 'Shared song');
      expect(player.state.position.inMilliseconds, closeTo(5000, 100));
      expect(player.loadedRemoteSource!.headers, {
        'Authorization': 'Bearer guest-token',
      });
      expect(player.state.itemId, isNull);
      final loads = player.loads;
      await guarded.pause();
      await guarded.seek(const Duration(seconds: 99));
      await queue.next();
      queue.setShuffle(true);
      expect(player.state.status, PlaybackStatus.playing);
      expect(player.loads, loads);
      expect(queue.state.shuffleEnabled, false);
      expect(api.calls.last, endsWith('/command'));
      expect(api.bodies.last?['action'], 'next');
      await queue.previous();
      expect(api.bodies.last?['action'], 'previous');
      queue.removeAt(1);
      await Future<void>.delayed(Duration.zero);
      expect(api.bodies.last?['slot'], 'second');
      await guarded.setVolume(.3);
      expect(player.state.volume, .3);
      api.data = {...api.data, 'playing': false, 'positionMs': 24000};
      await party.poll();
      expect(player.state.status, PlaybackStatus.paused);
      expect(player.state.position, const Duration(seconds: 24));
      api.data = {...api.data, 'playing': true, 'index': 1, 'positionMs': 0};
      await party.poll();
      expect(player.state.title, 'Next song');
      expect(queue.state.currentIndex, 1);
      expect(player.state.status, PlaybackStatus.playing);
      await party.leave();
      expect(party.active, false);
      expect(player.state.title, 'My song');
      expect(player.state.position, const Duration(seconds: 42));
      expect(player.state.volume, .3);
      expect(queue.state.items.first.itemId, 'own');
    },
  );
  test(
    'expired session leaves cleanly and bad requests never begin playback',
    () async {
      final player = Player(), api = Api();
      final queue = PlaybackQueueController(playbackController: player);
      final connection = JellyfinConnectionController(
        apiFactory: (_) => fixtures.FakeJellyfinApi(),
        credentialStore: fixtures.FakeCredentialStore(),
      );
      final connect = ConnectController(
        connection: connection,
        api: Service(),
        preferences: Preferences(),
      );
      final party = PartyController(
        api: api,
        connect: connect,
        playback: player,
        queue: queue,
      );
      addTearDown(() async {
        party.dispose();
        connect.dispose();
        await queue.dispose();
        await player.dispose();
        await connection.dispose();
      });
      api.failure = const PartyException('Invalid invite', 403);
      await party.join(
        PartyInvite(Uri.parse('https://music.example'), 'a' * 32, 'b' * 43),
        'Guest',
      );
      expect(party.active, false);
      expect(player.loads, 0);
      api.failure = null;
      await party.join(
        PartyInvite(Uri.parse('https://music.example'), 'a' * 32, 'b' * 43),
        'Guest',
      );
      api.failure = const PartyException('This session has ended.', 410);
      await party.poll();
      expect(party.active, false);
      expect(party.error, contains('ended'));
      expect(queue.state.items, isEmpty);
      expect(player.state.status, PlaybackStatus.stopped);
    },
  );
}
