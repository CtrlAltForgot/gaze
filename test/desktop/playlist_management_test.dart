import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/playlists_page.dart';
import 'package:gaze/desktop/queue_panel.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/playlist_summary.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/library/track_summary.dart';
import '../widget_test.dart' as fixtures;

SongSummary song(String entry) => SongSummary(
  track: const TrackSummary(
    id: 'track-one',
    title: 'Song One',
    artist: 'Artist',
    duration: Duration(minutes: 3),
  ),
  album: 'Album',
  entryId: entry,
);

class ManagedApi extends fixtures.FakeJellyfinApi {
  final playlists = <String, String>{'mix': 'Evening mix'};
  final songs = <String, List<SongSummary>>{
    'mix': [song('entry-one'), song('entry-two')],
  };
  List<String> createdItems = [];
  List<String> addedItems = [];
  int removals = 0;
  int deletes = 0;
  bool writable = true;
  bool failCreate = false;
  @override
  Future<PlaylistPage> getPlaylists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => PlaylistPage(
    playlists: playlists.entries
        .map(
          (p) => PlaylistSummary(
            id: p.key,
            title: p.value,
            trackCount: songs[p.key]!.length,
          ),
        )
        .toList(),
    totalCount: playlists.length,
  );
  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) async => SongPage(
    songs: List.of(songs[playlistId]!),
    totalCount: songs[playlistId]!.length,
  );
  @override
  Future<PlaylistSummary> createPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String name,
    List<String> itemIds = const [],
  }) async {
    if (failCreate)
      throw const JellyfinConnectionException('Could not save this playlist.');
    createdItems = List.of(itemIds);
    final id = 'playlist-${playlists.length}';
    playlists[id] = name;
    songs[id] = [];
    return PlaylistSummary(id: id, title: name, trackCount: 0);
  }

  @override
  Future<bool> canEditPlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => writable;
  @override
  Future<PlaylistSummary> getPlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => PlaylistSummary(
    id: playlistId,
    title: playlists[playlistId]!,
    trackCount: songs[playlistId]!.length,
  );

  @override
  Future<PlaylistSummary> updatePlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
    required String description,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) async {
    playlists[playlistId] = name;
    return PlaylistSummary(
      id: playlistId,
      title: name,
      description: description,
      trackCount: songs[playlistId]!.length,
    );
  }

  @override
  Future<void> renamePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String name,
  }) async {
    playlists[playlistId] = name;
  }

  @override
  Future<void> addPlaylistSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required List<String> itemIds,
  }) async {
    addedItems = List.of(itemIds);
    for (final _ in itemIds) {
      songs[playlistId]!.add(song('entry-${songs[playlistId]!.length + 3}'));
    }
  }

  @override
  Future<void> removePlaylistEntry({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required String entryId,
  }) async {
    removals++;
    songs[playlistId]!.removeWhere((song) => song.entryId == entryId);
  }

  @override
  Future<void> deletePlaylist({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async {
    deletes++;
    playlists.remove(playlistId);
    songs.remove(playlistId);
  }
}

Future<void> mount(WidgetTester tester, ManagedApi api) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(tester.view.reset);
  final ctl = JellyfinConnectionController(
    apiFactory: (_) => api,
    credentialStore: fixtures.FakeCredentialStore(),
  );
  addTearDown(ctl.dispose);
  await ctl.connect(
    serverAddress: 'https://music.example',
    userName: 'listener',
    password: 'test-password',
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlaylistsPage(
          connectionController: ctl,
          onConnect: () {},
          onPlaySongs: (_, _) async {},
          onQueueSongs: (_, _) async {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'grid single click opens while double click plays the collection',
    (tester) async {
      final api = ManagedApi();
      final ctl = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: fixtures.FakeCredentialStore(),
      );
      await ctl.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      addTearDown(ctl.dispose);
      int plays = 0;
      List<SongSummary>? played;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistsPage(
              connectionController: ctl,
              onConnect: () {},
              onPlaySongs: (_, _) async {},
              onQueueSongs: (_, _) async {},
              onPlayPlaylist: (songs) async {
                plays++;
                played = songs;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('playlist-card-mix'));
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(plays, 1);
      expect(played?.length, 2);
      await tester.tap(find.text('All playlists'));
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(plays, 1);
      expect(find.byTooltip('Play playlist'), findsOneWidget);
    },
  );

  testWidgets(
    'the song picker labels and disables songs already saved in the playlist',
    (tester) async {
      final api = ExistingSongApi();
      await mount(tester, api);
      await tester.tap(find.text('Evening mix'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Playlist options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add songs').first);
      await tester.pumpAndSettle();
      expect(find.text('Already in playlist'), findsOneWidget);
      final savedSong = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Song One'),
      );
      expect(savedSong.onTap, isNull);
      await tester.tap(find.text('Other Song'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Add songs'),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.addedItems, ['other']);
    },
  );

  testWidgets(
    'selects library songs and saves them into the account playlist',
    (tester) async {
      final api = ManagedApi();
      await mount(tester, api);
      await tester.tap(find.text('Evening mix'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Playlist options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add songs').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('A Library Song'));
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Add songs')),
      );
      await tester.pumpAndSettle();
      expect(api.addedItems, ['song-id']);
      expect(api.songs['mix']!.length, 3);
    },
  );
  testWidgets(
    'saving the queue includes the current and upcoming songs and preserves playback',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 720);
      addTearDown(tester.view.reset);
      final api = ManagedApi();
      final ctl = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: fixtures.FakeCredentialStore(),
      );
      addTearDown(ctl.dispose);
      await ctl.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test-password',
      );
      final playback = fixtures.FakePlaybackController();
      final queue = PlaybackQueueController(playbackController: playback);
      addTearDown(queue.dispose);
      addTearDown(playback.dispose);
      RemotePlaybackSource source(String id) => RemotePlaybackSource(
        uri: Uri.parse('https://music.example/$id'),
        title: id,
        artist: 'Artist',
        itemId: id,
      );
      await queue.playAlbum([
        source('past'),
        source('current'),
        source('next'),
      ], startIndex: 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: QueuePanel(
                controller: queue,
                connectionController: ctl,
                online: true,
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save queue as playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Saved queue');
      await tester.tap(find.text('Create playlist'));
      await tester.pumpAndSettle();
      expect(api.createdItems, ['current', 'next']);
      expect(playback.loadedRemoteSource!.itemId, 'current');
      expect(queue.state.currentIndex, 1);
    },
  );

  testWidgets('creates and renames a saved playlist in gaze', (tester) async {
    final api = ManagedApi();
    await mount(tester, api);
    await tester.tap(find.byTooltip('New playlist').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Travel');
    await tester.tap(find.text('Create playlist'));
    await tester.pumpAndSettle();
    expect(api.playlists.values, contains('Travel'));
    expect(find.text('This playlist is empty'), findsOneWidget);
    await tester.tap(find.byTooltip('Playlist options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name')),
      'Road trip',
    );
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(api.playlists.values, contains('Road trip'));
    expect(find.text('Road trip'), findsOneWidget);
  });
  testWidgets('failed creation keeps the entered name and reports failure', (
    tester,
  ) async {
    final api = ManagedApi()..failCreate = true;
    await mount(tester, api);
    await tester.tap(find.byTooltip('New playlist').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this name');
    await tester.tap(find.text('Create playlist'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this name',
    );
    expect(find.text('Could not save this playlist.'), findsOneWidget);
    expect(api.playlists.length, 1);
  });
  testWidgets(
    'song removal requires confirmation and removes one duplicate entry',
    (tester) async {
      final api = ManagedApi();
      await mount(tester, api);
      await tester.tap(find.text('Evening mix'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Song One').first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.removals, 0);
      await tester.tap(
        find.text('Song One').first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove song'));
      await tester.pumpAndSettle();
      expect(api.removals, 1);
      expect(api.songs['mix']!.single.entryId, 'entry-two');
    },
  );
  testWidgets(
    'playlist deletion requires confirmation and returns to the saved list',
    (tester) async {
      final api = ManagedApi();
      await mount(tester, api);
      await tester.tap(find.text('Evening mix'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Playlist options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete playlist'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your music files stay'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.deletes, 0);
      await tester.tap(find.byTooltip('Playlist options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete playlist'));
      await tester.pumpAndSettle();
      expect(api.deletes, 1);
      expect(find.text('No music playlists yet'), findsOneWidget);
    },
  );
  testWidgets(
    'read-only playlist access disables management while retaining playback',
    (tester) async {
      final api = ManagedApi()..writable = false;
      await mount(tester, api);
      await tester.tap(find.text('Evening mix'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.text('You have read-only access to this playlist.'),
        findsOneWidget,
      );
      final edit = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Edit details',
        ),
      );
      expect(edit.onPressed, isNull);
      final play = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Play playlist',
        ),
      );
      expect(play.onPressed, isNotNull);
    },
  );
}

class ExistingSongApi extends ManagedApi {
  @override
  Future<SongPage> getSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async => SongPage(
    songs: [
      song('library-entry'),
      const SongSummary(
        track: TrackSummary(
          id: 'other',
          title: 'Other Song',
          artist: 'Artist',
          duration: Duration(minutes: 3),
        ),
        album: 'Album',
      ),
    ],
    totalCount: 2,
  );
}
