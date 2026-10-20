import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/playlist_details_dialog.dart';
import 'package:gaze/desktop/playlists_page.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/playlist_summary.dart';

import '../widget_test.dart' as fixtures;
import 'playlist_management_test.dart' as management;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _EditingApi extends management.ManagedApi {
  String description = 'Old description';
  Uint8List? uploaded;
  String? mime;
  int updates = 0;
  bool failImageOnce = false;
  Completer<void>? pending;
  @override
  Future<PlaylistSummary> getPlaylistDetails({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
  }) async => PlaylistSummary(
    id: playlistId,
    title: playlists[playlistId]!,
    trackCount: songs[playlistId]!.length,
    description: description,
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
    updates++;
    await pending?.future;
    playlists[playlistId] = name;
    this.description = description;
    final saved = PlaylistSummary(
      id: playlistId,
      title: name,
      description: description,
      trackCount: 2,
      imageTag: 'new-cover',
    );
    if (failImageOnce) {
      failImageOnce = false;
      throw JellyfinPlaylistUpdateException(
        'Details saved, but the image could not be uploaded. Try saving again.',
        savedPlaylist: saved,
      );
    }
    uploaded = imageBytes;
    mime = imageMimeType;
    return saved;
  }
}

Future<JellyfinConnectionController> _controller(_EditingApi api) async {
  final controller = JellyfinConnectionController(
    apiFactory: (_) => api,
    credentialStore: fixtures.FakeCredentialStore(),
  );
  addTearDown(controller.dispose);
  await controller.connect(
    serverAddress: 'https://music.example',
    userName: 'listener',
    password: 'test-password',
  );
  return controller;
}

Future<void> _dialog(
  WidgetTester tester,
  JellyfinConnectionController controller, {
  Uint8List? image,
  ValueChanged<PlaylistSummary>? onSaved,
  Size size = const Size(1280, 800),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPlaylistDetailsDialog(
              context,
              controller,
              const PlaylistSummary(
                id: 'mix',
                title: 'Evening mix',
                description: 'Old description',
              ),
              onSaved: onSaved,
              chooseCover: () async =>
                  image == null ? null : PlaylistCoverSelection(image),
            ),
            child: const Text('Edit'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'edits title, description and selected image together without saving on selection',
    (tester) async {
      final api = _EditingApi();
      final controller = await _controller(api);
      await _dialog(tester, controller, image: _png);
      await tester.enterText(
        find.byKey(const ValueKey('playlist-name')),
        'Road trip',
      );
      await tester.enterText(
        find.byKey(const ValueKey('playlist-description')),
        'Windows down.',
      );
      await tester.tap(find.text('Choose image'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Undo image change'), findsOneWidget);
      expect(api.updates, 0);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(api.playlists['mix'], 'Road trip');
      expect(api.description, 'Windows down.');
      expect(api.uploaded, _png);
      expect(api.mime, 'image/png');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('partial image failure retains preview and draft for retry', (
    tester,
  ) async {
    final api = _EditingApi()..failImageOnce = true;
    final controller = await _controller(api);
    final saved = <PlaylistSummary>[];
    await _dialog(tester, controller, image: _png, onSaved: saved.add);
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name')),
      'Keep my title',
    );
    await tester.tap(find.text('Choose image'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Details saved, but'), findsOneWidget);
    expect(find.text('Undo image change'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('playlist-name')))
          .controller!
          .text,
      'Keep my title',
    );
    expect(saved.single.title, 'Keep my title');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(api.uploaded, _png);
    expect(api.updates, 2);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'rejects invalid image before a server write and cancel retains original',
    (tester) async {
      final api = _EditingApi();
      final controller = await _controller(api);
      await _dialog(tester, controller, image: Uint8List.fromList([1, 2, 3]));
      await tester.tap(find.text('Choose image'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a JPEG, PNG, or WebP image.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('playlist-name')),
        'Cancelled name',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.updates, 0);
      expect(api.playlists['mix'], 'Evening mix');
    },
  );

  testWidgets(
    'blocks edits after sign out instead of writing to another account',
    (tester) async {
      final api = _EditingApi();
      final controller = await _controller(api);
      await _dialog(tester, controller);
      await controller.disconnect();
      await tester.pumpAndSettle();
      expect(find.textContaining('Your connection changed.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save changes'),
            )
            .onPressed,
        isNull,
      );
      expect(api.updates, 0);
    },
  );

  testWidgets('a pending save cannot be submitted twice or cancelled midway', (
    tester,
  ) async {
    final api = _EditingApi()..pending = Completer<void>();
    final controller = await _controller(api);
    await _dialog(tester, controller);
    await tester.tap(find.text('Save changes'));
    await tester.pump();
    expect(api.updates, 1);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Saving…'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );
    api.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(api.updates, 1);
  });

  testWidgets('narrow edit dialog remains scrollable without overflow', (
    tester,
  ) async {
    final api = _EditingApi();
    final controller = await _controller(api);
    await _dialog(tester, controller, size: const Size(400, 600));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('playlist-description')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('playlist-description')),
      'A longer description',
    );
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(api.description, 'A longer description');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sidebar selection can open another playlist and return to collection',
    (tester) async {
      final api = _EditingApi();
      api.playlists['other'] = 'Morning';
      api.songs['other'] = [];
      final controller = await _controller(api);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 720);
      addTearDown(tester.view.reset);
      Future<void> show(PlaylistSummary? playlist, {int revision = 0}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaylistsPage(
                connectionController: controller,
                initialPlaylist: playlist,
                navigationRevision: revision,
                onConnect: () {},
                onPlaySongs: (_, _) async {},
                onQueueSongs: (_, _) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(const PlaylistSummary(id: 'mix', title: 'Evening mix'));
      expect(find.text('All playlists'), findsOneWidget);
      expect(find.text('Evening mix'), findsOneWidget);
      await show(const PlaylistSummary(id: 'other', title: 'Morning'));
      expect(find.text('This playlist is empty'), findsOneWidget);
      expect(find.text('Morning'), findsOneWidget);
      await tester.tap(find.text('All playlists'));
      await tester.pumpAndSettle();
      expect(find.text('All playlists'), findsNothing);
      await show(
        const PlaylistSummary(id: 'other', title: 'Morning'),
        revision: 1,
      );
      expect(find.text('All playlists'), findsOneWidget);
      expect(find.text('This playlist is empty'), findsOneWidget);
      await show(null, revision: 2);
      expect(find.text('All playlists'), findsNothing);
      expect(find.text('Evening mix'), findsOneWidget);
      expect(find.text('Morning'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
