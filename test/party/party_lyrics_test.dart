import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/connect/connect_controller.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/track_lyrics.dart';
import 'package:gaze/party/party_api.dart';
import 'package:gaze/party/party_controller.dart';
import 'package:gaze/party/party_playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import '../widget_test.dart' as fixtures;
import '../desktop/connect_workflows_test.dart' show Preferences, Service;
import '../lyrics/lyrics_resolution_test.dart' show Provider, timed;
import 'party_test.dart' show Api, Player;

class GuestLibrary extends fixtures.FakeJellyfinApi {
  int lyricCalls = 0;
  @override
  Future<TrackLyrics?> getLyrics({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String trackId,
  }) async {
    lyricCalls++;
    throw StateError(
      'A guest must never read a host ID from their own library',
    );
  }
}

class GuestLyricsApi extends Api {
  GuestLyricsApi() {
    data['playing'] = false;
  }
  bool plain = false, missing = false;
  PartyException? lyricsFailure;
  Completer<Map<String, dynamic>>? pendingLyrics;
  final lyricTokens = <String>[];
  final lyricPaths = <String>[];
  Map<String, dynamic> result(String label) => {
    'lyrics': missing
        ? null
        : {
            'isSynchronized': !plain,
            'lines': [
              {'text': '$label first line', if (!plain) 'startMicroseconds': 0},
              {
                'text': '$label second line',
                if (!plain) 'startMicroseconds': 12000000,
              },
            ],
          },
  };
  @override
  Future<Map<String, dynamic>> request(
    Uri server,
    String token,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (path.contains('/lyrics/')) {
      lyricTokens.add(token);
      lyricPaths.add(path);
      if (lyricsFailure != null) throw lyricsFailure!;
      return pendingLyrics?.future ??
          result(path.endsWith('b' * 32) ? 'Shared' : 'Next');
    }
    if (path.endsWith('/command') && body?['action'] == 'seek') {
      data = {...data, 'positionMs': body!['positionMs']};
    }
    return super.request(server, token, path, body: body);
  }
}

class GuestLyricsFixture {
  GuestLyricsFixture({this.provider}) {
    connection = JellyfinConnectionController(
      credentialStore: fixtures.FakeCredentialStore(),
      apiFactory: (_) => library,
      lyricsProvider: provider,
    );
    connect = ConnectController(
      connection: connection,
      api: Service(),
      preferences: Preferences(),
    );
    guarded = PartyPlaybackController(
      player,
      () => party.following,
      command: (action, data) => party.command(action, data),
    );
    queue = PlaybackQueueController(playbackController: guarded);
    party = PartyController(
      api: api,
      connect: connect,
      playback: player,
      queue: queue,
    );
  }
  final Provider? provider;
  final library = GuestLibrary();
  final player = Player();
  final api = GuestLyricsApi();
  late final JellyfinConnectionController connection;
  late final ConnectController connect;
  late final PartyPlaybackController guarded;
  late final PlaybackQueueController queue;
  late final PartyController party;
  Future<void> join() => party.join(
    PartyInvite(Uri.parse('https://party.example'), 'a' * 32, 'b' * 43),
    'Guest',
  );
  Future<void> dispose() async {
    party.dispose();
    connect.dispose();
    await queue.dispose();
    await player.dispose();
    await connection.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final signedIn in [false, true]) {
    test(
      'guest lyrics use only the host session, saved account: $signedIn',
      () async {
        final provider = Provider();
        final f = GuestLyricsFixture(provider: provider);
        addTearDown(f.dispose);
        if (signedIn)
          await f.connection.connect(
            serverAddress: 'https://own.example',
            userName: 'Guest',
            password: 'test',
          );
        await f.join();
        final result = await f.party.loadLyrics();
        expect(result!.hasTiming, true);
        expect(result.lines[1].start, const Duration(seconds: 12));
        expect(result.lines.first.text, 'Shared first line');
        expect(f.api.lyricTokens, ['guest-token']);
        expect(
          f.api.lyricPaths.single,
          '/v1/parties/${'a' * 32}/lyrics/${'b' * 32}',
        );
        expect(f.library.lyricCalls, 0);
        expect(provider.calls, 0);
        expect(f.player.state.itemId, isNull);
      },
    );
  }
  test(
    'plain lyrics upgrade, survive lookup failure, and old services use lookup',
    () async {
      final provider = Provider();
      final f = GuestLyricsFixture(provider: provider);
      addTearDown(f.dispose);
      await f.join();
      f.api.plain = true;
      expect(await f.party.loadLyrics(), same(timed));
      provider.fail = true;
      final plain = await f.party.loadLyrics();
      expect(plain!.hasTiming, false);
      expect(plain.lines.first.text, 'Shared first line');
      provider.fail = false;
      f.api.lyricsFailure = const PartyException('Old service', 404);
      expect(await f.party.loadLyrics(), same(timed));
      provider.result = null;
      expect(await f.party.loadLyrics(), isNull);
      f.api.lyricsFailure = const PartyException('Unavailable', 502);
      provider.fail = true;
      await expectLater(f.party.loadLyrics(), throwsStateError);
      expect(f.library.lyricCalls, 0);
    },
  );
  test(
    'missing lyrics are empty and session changes discard late responses',
    () async {
      final f = GuestLyricsFixture();
      addTearDown(f.dispose);
      await f.join();
      f.api.missing = true;
      expect(await f.party.loadLyrics(), isNull);
      f.api.missing = false;
      final pending = Completer<Map<String, dynamic>>();
      f.api.pendingLyrics = pending;
      final request = f.party.loadLyrics();
      await f.party.leave();
      pending.complete(f.api.result('Obsolete'));
      expect(await request, isNull);
      expect(f.party.lyricsIdentity, isNull);
    },
  );
}
