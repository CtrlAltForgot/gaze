import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/playlists_page.dart';
import 'package:gaze/desktop/song_row.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/playlist_summary.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/library/track_summary.dart';

import '../widget_test.dart' as fixtures;
import 'playlist_management_test.dart' show ManagedApi;

SongSummary _song(
  String entry,
  String title,
  String artist,
  String album, {
  String? trackId,
}) => SongSummary(
  track: TrackSummary(
    id: trackId ?? entry,
    title: title,
    artist: artist,
    duration: const Duration(minutes: 3),
  ),
  album: album,
  entryId: entry,
);

class SearchPlaylistApi extends ManagedApi {
  SearchPlaylistApi() {
    songs['mix'] = [
      _song('opening', 'Opening', 'North', 'First Album'),
      _song(
        'duplicate-one',
        'Midnight Drive',
        'Mira Lane',
        'Blue Hours',
        trackId: 'duplicate-track',
      ),
      _song('home', 'Home', 'South', 'Last Album'),
      _song(
        'duplicate-two',
        'Midnight Drive',
        'Mira Lane',
        'Blue Hours',
        trackId: 'duplicate-track',
      ),
      _song('finale', 'Finale', 'North', 'Second Album'),
    ];
    playlists['other'] = 'Other mix';
    songs['other'] = [_song('other-song', 'Elsewhere', 'East', 'New Album')];
  }

  final requests = <int>[];
  final removedEntries = <String>[];
  final moves = <(String, int)>[];

  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) {
    requests.add(startIndex);
    return super.getPlaylistTracks(
      address: address,
      session: session,
      playlistId: playlistId,
      startIndex: startIndex,
      limit: limit,
    );
  }

  @override
  Future<void> removePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
  }) {
    removedEntries.add(entryId);
    return super.removePlaylistEntry(
      address: address,
      session: session,
      playlistId: playlistId,
      entryId: entryId,
    );
  }

  @override
  Future<void> movePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
    required int newIndex,
  }) async {
    moves.add((entryId, newIndex));
    final entries = songs[playlistId]!;
    final oldIndex = entries.indexWhere((song) => song.entryId == entryId);
    entries.insert(newIndex, entries.removeAt(oldIndex));
  }
}

class PagedSearchPlaylistApi extends SearchPlaylistApi {
  final laterPage = Completer<SongPage>();

  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) async {
    requests.add(startIndex);
    if (startIndex == 0) {
      return SongPage(
        songs: [songs[playlistId]!.first],
        totalCount: 2,
        nextStartIndex: 1,
      );
    }
    return laterPage.future;
  }
}

const _searchKey = ValueKey('playlist-search');
Finder get _search => find.byKey(_searchKey);

Future<JellyfinConnectionController> _mount(
  WidgetTester tester,
  SearchPlaylistApi api, {
  Future<void> Function(List<SongSummary>, int)? onPlay,
  Future<void> Function(List<SongSummary>, bool)? onQueue,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1000);
  addTearDown(tester.view.reset);
  final connection = JellyfinConnectionController(
    apiFactory: (_) => api,
    credentialStore: fixtures.FakeCredentialStore(),
  );
  addTearDown(connection.dispose);
  await connection.connect(
    serverAddress: 'https://music.example',
    userName: 'listener',
    password: 'test-password',
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlaylistsPage(
          connectionController: connection,
          initialPlaylist: const PlaylistSummary(
            id: 'mix',
            title: 'Evening mix',
            trackCount: 5,
          ),
          onConnect: () {},
          onPlaySongs: onPlay ?? (_, _) async {},
          onQueueSongs: onQueue ?? (_, _) async {},
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return connection;
}

Future<void> _query(WidgetTester tester, String query) async {
  await tester.ensureVisible(_search);
  await tester.enterText(_search, query);
  await tester.pumpAndSettle();
}

List<String?> _visibleEntries(WidgetTester tester) => tester
    .widgetList<SongRow>(find.byType(SongRow))
    .map((row) => row.song.entryId)
    .toList();

void main() {
  testWidgets(
    'single click selects, double click plays, and right click opens playlist actions',
    (tester) async {
      final api = SearchPlaylistApi();
      final played = <int>[];
      await _mount(
        tester,
        api,
        onPlay: (_, index) async {
          played.add(index);
        },
      );
      Finder selected() => find.descendant(
        of: find.byType(SongRow),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.selected == true,
        ),
      );
      await tester.tap(find.text('Opening'));
      await tester.pumpAndSettle();
      expect(played, isEmpty);
      expect(selected(), findsOneWidget);
      await tester.tap(find.text('Finale'));
      await tester.pumpAndSettle();
      expect(played, isEmpty);
      expect(selected(), findsOneWidget);
      expect(
        find.descendant(of: selected(), matching: find.text('Finale')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(played, [4]);
      await tester.tap(find.text('Midnight Drive').last);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('Midnight Drive').last);
      await tester.pumpAndSettle();
      expect(played, [4, 3]);
      await tester.tap(find.text('Opening'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(played, [4, 3]);
      expect(find.text('Add to playlist…'), findsOneWidget);
      await tester.tap(find.text('Add to playlist…'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Other mix'), findsOneWidget);
      await tester.tap(find.text('Other mix'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.addedItems, ['opening']);
      expect(played, [4, 3]);
    },
  );

  testWidgets(
    'playlist controls stay compact with a visible search box at desktop widths',
    (tester) async {
      await _mount(tester, SearchPlaylistApi());
      expect(find.text('Play playlist'), findsNothing);
      expect(find.text('Edit details'), findsNothing);
      expect(find.text('Add songs'), findsNothing);
      expect(find.byTooltip('Edit details'), findsOneWidget);
      for (final width in [520.0, 660.0, 1120.0, 2048.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_search);
        await tester.pumpAndSettle();
        expect(tester.getSize(_search).width, greaterThan(200));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('playlist search matches title, artist and album locally', (
    tester,
  ) async {
    final api = SearchPlaylistApi();
    await _mount(tester, api);
    final requestCount = api.requests.length;
    expect(find.text('Search this playlist'), findsOneWidget);

    await _query(tester, '  MiDnIgHt  ');
    expect(_visibleEntries(tester), ['duplicate-one', 'duplicate-two']);
    await _query(tester, 'mIrA   bLuE');
    expect(_visibleEntries(tester), ['duplicate-one', 'duplicate-two']);
    await _query(tester, 'FIRST ALBUM');
    expect(_visibleEntries(tester), ['opening']);
    await _query(tester, 'missing song');
    expect(find.text('No matching songs'), findsOneWidget);
    expect(find.byType(SongRow), findsNothing);
    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(_visibleEntries(tester), api.songs['mix']!.map((s) => s.entryId));

    await _query(tester, 'North');
    await tester.tap(find.byTooltip('Clear playlist search'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
    expect(_visibleEntries(tester).length, 5);
    await _query(tester, '   ');
    expect(_visibleEntries(tester).length, 5);
    expect(api.requests.length, requestCount);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a filtered result plays its original position and queues itself',
    (tester) async {
      final api = SearchPlaylistApi();
      List<SongSummary>? played;
      int? startIndex;
      List<SongSummary>? queued;
      bool? next;
      await _mount(
        tester,
        api,
        onPlay: (songs, index) async {
          played = songs;
          startIndex = index;
        },
        onQueue: (songs, playNext) async {
          queued = songs;
          next = playNext;
        },
      );
      await _query(tester, 'midnight');
      expect(find.text('2'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      await tester.tap(find.text('Midnight Drive').last);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('Midnight Drive').last);
      await tester.pumpAndSettle();
      expect(startIndex, 3);
      expect(
        played!.map((s) => s.entryId),
        api.songs['mix']!.map((s) => s.entryId),
      );
      await tester.tap(
        find.text('Midnight Drive').last,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(queued!.single.entryId, 'duplicate-two');
      expect(next, isTrue);
      await tester.tap(find.byTooltip('Play playlist'));
      await tester.pumpAndSettle();
      expect(startIndex, 0);
      expect(played!.length, 5);
    },
  );

  testWidgets('filtering removes the chosen duplicate and disables moving', (
    tester,
  ) async {
    final api = SearchPlaylistApi();
    await _mount(tester, api);
    await _query(tester, 'midnight');
    await tester.tap(
      find.text('Midnight Drive').last,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    for (final label in ['Move up', 'Move down']) {
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, label),
            )
            .enabled,
        isFalse,
      );
    }
    await tester.tap(find.text('Remove from playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove song'));
    await tester.pumpAndSettle();
    expect(api.removedEntries, ['duplicate-two']);
    expect(_visibleEntries(tester), ['duplicate-one']);
    expect(tester.widget<TextField>(_search).controller!.text, 'midnight');
    await tester.tap(find.byTooltip('Clear playlist search'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('Midnight Drive'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move down'));
    await tester.pumpAndSettle();
    expect(api.moves, [('duplicate-one', 2)]);
    expect(api.songs['mix']![2].entryId, 'duplicate-one');
  });

  testWidgets(
    'refresh and editing keep the query; a different playlist clears it',
    (tester) async {
      await _mount(tester, SearchPlaylistApi());
      await _query(tester, 'midnight');
      await tester.tap(find.byTooltip('Refresh playlists'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, 'midnight');
      expect(_visibleEntries(tester), ['duplicate-one', 'duplicate-two']);
      await tester.tap(find.byTooltip('Edit details'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('playlist-name')),
        'Renamed mix',
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, 'midnight');
      expect(_visibleEntries(tester), ['duplicate-one', 'duplicate-two']);
      await tester.tap(find.text('All playlists'));
      await tester.pumpAndSettle();
      expect(_search, findsNothing);
      await tester.tap(find.text('Other mix'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
      expect(_visibleEntries(tester), ['other-song']);
    },
  );

  testWidgets('signing out clears the previous account playlist query', (
    tester,
  ) async {
    final connection = await _mount(tester, SearchPlaylistApi());
    await _query(tester, 'midnight');
    await connection.disconnect();
    await tester.pumpAndSettle();
    expect(_search, findsNothing);
    await connection.connect(
      serverAddress: 'https://music.example',
      userName: 'listener',
      password: 'test-password',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Evening mix'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
    expect(_visibleEntries(tester).length, 5);
  });

  testWidgets(
    'later playlist pages can match without a premature empty result',
    (tester) async {
      final api = PagedSearchPlaylistApi();
      await _mount(tester, api, settle: false);
      await tester.enterText(_search, 'midnight');
      await tester.pump();
      expect(api.requests, [0, 1]);
      expect(find.text('No matching songs'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      api.laterPage.complete(
        SongPage(songs: [api.songs['mix']![1]], totalCount: 2),
      );
      await tester.pumpAndSettle();
      expect(_visibleEntries(tester), ['duplicate-one']);
      expect(find.text('No matching songs'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
