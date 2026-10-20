import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/playlist_summary.dart';
import 'package:gaze/main.dart';

import '../widget_test.dart' as fixtures;
import 'playlist_management_test.dart' show ManagedApi;

class SidebarApi extends ManagedApi {
  int detailRequests = 0;
  final Completer<PlaylistPage>? pending;
  SidebarApi({this.pending});

  @override
  Future<PlaylistPage> getPlaylists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) =>
      pending?.future ??
      super.getPlaylists(
        address: address,
        session: session,
        startIndex: startIndex,
        limit: limit,
      );

  @override
  Future<PlaylistSummary> getPlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) {
    detailRequests++;
    return super.getPlaylistDetails(
      address: address,
      session: session,
      playlistId: playlistId,
    );
  }
}

Future<JellyfinConnectionController> mount(
  WidgetTester tester,
  SidebarApi api,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final connection = JellyfinConnectionController(
    apiFactory: (_) => api,
    credentialStore: fixtures.FakeCredentialStore(),
  );
  await connection.connect(
    serverAddress: 'https://music.example',
    userName: 'listener',
    password: 'test',
  );
  await tester.pumpWidget(
    GazeApp(
      playbackController: fixtures.FakePlaybackController(),
      connectionController: connection,
    ),
  );
  await tester.pumpAndSettle();
  return connection;
}

void main() {
  testWidgets('double click on a sidebar playlist starts playback once', (
    tester,
  ) async {
    await mount(tester, SidebarApi());
    final playback =
        tester.widget<GazeApp>(find.byType(GazeApp)).playbackController
            as fixtures.FakePlaybackController;
    final shortcut = find.byKey(const ValueKey('sidebar-playlist-mix'));
    await tester.tap(shortcut);
    await tester.pump(const Duration(milliseconds: 70));
    expect(playback.loadedRemoteSource, isNull);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expect(playback.loadedRemoteSource?.title, 'Song One');
  });

  testWidgets('hover help is reserved for unlabeled controls', (tester) async {
    await mount(tester, SidebarApi());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    final shortcut = find.byKey(const ValueKey('sidebar-playlist-mix'));
    await mouse.moveTo(tester.getCenter(shortcut));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip('Evening mix'), findsNothing);
    expect(find.text('Evening mix'), findsOneWidget);
    expect(find.byTooltip('Connections'), findsNothing);

    await tester.tap(shortcut);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.byTooltip('Edit details')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Edit details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sidebar opens playlists, retains them across tabs, and can reopen after Back',
    (tester) async {
      final api = SidebarApi();
      await mount(tester, api);
      final shortcut = find.byKey(const ValueKey('sidebar-playlist-mix'));
      expect(shortcut, findsOneWidget);
      await tester.tap(shortcut);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Song One'), findsNWidgets(2));
      final requests = api.detailRequests;
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();
      expect(api.detailRequests, requests);
      await tester.tap(shortcut);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Song One'), findsNWidgets(2));
      await tester.tap(find.text('All playlists'));
      await tester.pumpAndSettle();
      expect(find.text('Song One'), findsNothing);
      await tester.tap(shortcut);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Song One'), findsNWidgets(2));
      await tester.tap(find.text('Playlists').first);
      await tester.pumpAndSettle();
      expect(find.text('Song One'), findsNothing);
      expect(find.byTooltip('New playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late playlist shortcuts cannot reappear after signing out', (
    tester,
  ) async {
    final pending = Completer<PlaylistPage>();
    final connection = await mount(tester, SidebarApi(pending: pending));
    await connection.disconnect();
    await tester.pumpAndSettle();
    pending.complete(
      const PlaylistPage(
        playlists: [
          PlaylistSummary(
            id: 'private',
            title: 'Private playlist',
            trackCount: 1,
          ),
        ],
        totalCount: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private playlist'), findsNothing);
    expect(find.text('Your playlists'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
