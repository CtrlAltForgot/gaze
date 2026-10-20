import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/artist_links.dart';
import 'package:gaze/desktop/artists_page.dart';
import 'package:gaze/desktop/track_selection.dart';
import 'package:gaze/artists/artist_profile_provider.dart';
import 'package:gaze/library/artist_profile.dart';
import 'package:gaze/library/artist_summary.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/library/track_summary.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/storage/local_content_cache.dart';
import 'package:gaze/storage/sqlite_library_metadata_cache.dart';
import '../widget_test.dart' as fixtures;

class ArtistsApi extends fixtures.FakeJellyfinApi {
  final offsets = <int>[];
  bool newlyAdded = false;
  @override
  Future<ArtistPage> getArtists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async {
    offsets.add(startIndex);
    return ArtistPage(
      artists: startIndex == 0
          ? [
              const ArtistSummary(id: 'combined', name: 'Lead; Guest'),
              const ArtistSummary(id: 'band', name: 'Earth, Wind & Fire'),
            ]
          : [
              const ArtistSummary(id: 'guest', name: 'Guest'),
              if (newlyAdded)
                const ArtistSummary(id: 'new', name: 'New Artist'),
            ],
      totalCount: newlyAdded ? 4 : 3,
    );
  }

  @override
  Future<SongPage> getSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => const SongPage(
    songs: [
      SongSummary(
        track: TrackSummary(
          id: 'hit',
          title: 'Shared hit',
          artist: 'Lead; Guest',
          duration: Duration(minutes: 3),
        ),
        album: 'Shared album',
        albumId: 'album',
      ),
    ],
    totalCount: 1,
  );
}

class Profiles implements ArtistProfileProvider {
  final completer = Completer<ArtistProfile?>();
  @override
  Future<ArtistProfile?> find(
    String name, {
    List<String> recordings = const [],
  }) => completer.future;
}

void main() {
  test(
    'all source pages are merged; new artists appear on refresh and the cached catalogue appears before refresh',
    () async {
      final api = ArtistsApi();
      final cache = SqliteLocalContentCache.inMemory();
      final ctl = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: fixtures.FakeCredentialStore(),
        contentCache: cache,
      );
      addTearDown(ctl.dispose);
      addTearDown(cache.dispose);
      await ctl.connect(
        serverAddress: 'http://music.local:8096',
        userName: 'listener',
        password: 'test',
      );
      final first = await ctl.watchArtistCatalog().last;
      expect(api.offsets, [0, 2]);
      expect(first.map((a) => a.name), ['Earth, Wind & Fire', 'Guest', 'Lead']);
      api.newlyAdded = true;
      final emissions = await ctl.watchArtistCatalog().toList();
      expect(emissions.first.length, 3);
      expect(emissions.last.map((a) => a.name), contains('New Artist'));
    },
  );
  testWidgets(
    'artist links open each credit, support keyboard focus, and never play a row',
    (tester) async {
      final opened = <String>[];
      var played = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArtistNavigationScope(
              onOpenArtist: opened.add,
              child: TrackSelectionScope(
                child: SelectableTrack(
                  identity: 'row',
                  onPlay: () => played++,
                  builder: (_, _) => const SizedBox(
                    width: 180,
                    height: 50,
                    child: ArtistLinks('Lead; Guest'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Guest'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, ['Guest']);
      expect(played, 0);
      await tester.tap(find.text('Guest'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('Guest'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(played, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened.length, greaterThan(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'new artist pages use one template, show songs while profile loads, then verified facts',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = ArtistsApi();
      final profiles = Profiles();
      final cache = SqliteLibraryMetadataCache.inMemory();
      final ctl = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: fixtures.FakeCredentialStore(),
        metadataCache: cache,
        artistProfileProvider: profiles,
      );
      addTearDown(ctl.dispose);
      addTearDown(cache.close);
      await ctl.connect(
        serverAddress: 'http://music.local:8096',
        userName: 'listener',
        password: 'test',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArtistsPage(
              connectionController: ctl,
              onConnect: () {},
              onPlayTrack: (_, _, _) async {},
              initialArtist: 'Guest',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Shared hit'), findsOneWidget);
      expect(find.text('Loading artist details…'), findsOneWidget);
      profiles.completer.complete(
        const ArtistProfile(
          musicBrainzId: 'id',
          origin: 'Tacoma, United States',
          type: 'Person',
          born: '1990-01-01',
          biography: 'A short artist biography.',
          popularTitles: ['Unavailable', 'Shared hit'],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Popular in your library'), findsOneWidget);
      expect(find.text('A short artist biography.'), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);
      expect(find.textContaining('Tacoma, United States'), findsOneWidget);
      for (final width in [850.0, 1100.0]) {
        tester.view.physicalSize = Size(width, 850);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
