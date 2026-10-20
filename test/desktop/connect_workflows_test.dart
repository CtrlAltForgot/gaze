import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/connect/connect_controller.dart';
import 'package:gaze/connect/gaze_service_api.dart';
import 'package:gaze/design/gaze_theme.dart';
import 'package:gaze/desktop/connect_screen.dart';
import '../widget_test.dart' as support;

class Preferences implements ConnectPreferences {
  @override
  Future<String?> read(String serverId) async => null;
  @override
  Future<void> write(String serverId, String address) async {}
}

class Service implements GazeServiceApi {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  bool matched = false;
  bool artworkSearching = false;
  String importStatus = 'needsMatch';
  @override
  Future<Map<String, dynamic>> request(
    Uri address,
    String token,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add(path);
    if (body != null) bodies.add(body);
    if (path.endsWith('/match')) matched = true;
    if (path == '/v1/artwork/search') artworkSearching = true;
    if (path == '/v1/spotify/playlists')
      return {
        'items': [
          {
            'id': 'a' * 22,
            'name': 'Road trip',
            'count': 2,
            'owner': 'listener',
          },
        ],
      };
    if (path == '/v1/state')
      return {
        'spotify': {'connected': true, 'name': 'listener'},
        'synopti': {'enabled': true},
        'artwork': {
          'canManage': true,
          'status': artworkSearching ? 'queued' : 'complete',
          'found': 2,
          'missing': 1,
          'entries': [
            {
              'album': 'Rare album',
              'artists': ['Artist'],
              'status': 'noMatch',
              'error': 'No confident cover match was found.',
            },
          ],
        },
        'sources': [],
        'jobs': [
          {
            'id': 'c' * 32,
            'title': 'Saved song',
            'artists': ['Artist'],
            'status': 'ready',
          },
          {
            'id': 'd' * 32,
            'title': 'Ignored song',
            'artists': ['Artist'],
            'status': 'ignored',
          },
          {
            'id': 'b' * 32,
            'title': 'Unmatched recording',
            'artists': ['Artist'],
            'status': matched ? 'queued' : importStatus,
            'error': matched ? null : 'No confident match found.',
          },
        ],
      };
    return {'ok': true};
  }

  @override
  void close() {}
}

void main() {
  testWidgets('Connect supports narrow widths and manual matching', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(850, 740);
    addTearDown(tester.view.reset);
    final connection = support.createFakeConnectionController();
    await connection.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'test',
    );
    final service = Service();
    final controller = ConnectController(
      connection: connection,
      api: service,
      preferences: Preferences(),
    );
    await Future<void>.value();
    await controller.connect('http://music.local:8097');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildGazeTheme(),
        home: ConnectScreen(controller: controller, onClose: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Connected as listener'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Find missing artwork'));
    await tester.tap(find.text('Covers still missing (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Rare album'), findsOneWidget);
    await tester.tap(find.text('Find missing artwork'));
    await tester.pump();
    expect(service.calls, contains('/v1/artwork/search'));
    expect(find.text('Finding covers…'), findsOneWidget);
    expect(
      service.calls.where((path) => path == '/v1/spotify/playlists'),
      isEmpty,
    );
    service.artworkSearching = false;
    await controller.refresh();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Paste YouTube link'));
    await tester.tap(find.text('Paste YouTube link'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'YouTube video link'),
      'https://youtu.be/dQw4w9WgXcQ',
    );
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    expect(service.calls, contains('/v1/jobs/${'b' * 32}/match'));
    expect(service.bodies.last, {'url': 'https://youtu.be/dQw4w9WgXcQ'});
    await tester.tap(find.text('Needs attention (0)'));
    await tester.pumpAndSettle();
    expect(find.text('No imports need your attention.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await connection.dispose();
  });
  testWidgets('Spotify playlist selection sends only chosen playlist IDs', (
    tester,
  ) async {
    final connection = support.createFakeConnectionController();
    await connection.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'test',
    );
    final service = Service();
    final controller = ConnectController(
      connection: connection,
      api: service,
      preferences: Preferences(),
    );
    await Future<void>.value();
    await controller.connect('http://music.local:8097');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildGazeTheme(),
        home: ConnectScreen(controller: controller, onClose: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Choose playlists'));
    await tester.tap(find.text('Choose playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import playlist'));
    await tester.pumpAndSettle();
    expect(service.calls, contains('/v1/sources'));
    expect(service.bodies.last, {'id': 'a' * 22});
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await connection.dispose();
  });
  testWidgets(
    'sync queue removes resolved entries and refresh clears completed work',
    (tester) async {
      final connection = support.createFakeConnectionController();
      await connection.connect(
        serverAddress: 'http://music.local:8096',
        userName: 'listener',
        password: 'test',
      );
      final service = Service();
      final controller = ConnectController(
        connection: connection,
        api: service,
        preferences: Preferences(),
      );
      await Future<void>.value();
      await controller.connect('http://music.local:8097');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildGazeTheme(),
          home: ConnectScreen(controller: controller, onClose: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.jobs.length, 1);
      expect(find.text('Saved song'), findsNothing);
      expect(find.text('Ignored song'), findsNothing);
      expect(
        find.text('1 saved · 0 in progress · 1 need attention'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('In queue (1)'));
      await tester.tap(find.text('In queue (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Unmatched recording'), findsOneWidget);
      service.importStatus = 'ready';
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(controller.jobs, isEmpty);
      expect(find.text('Unmatched recording'), findsNothing);
      expect(find.text('In queue (0)'), findsOneWidget);
      expect(
        find.text('2 saved · 0 in progress · 0 need attention'),
        findsOneWidget,
      );
      expect(find.text('Your sync queue is clear.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await connection.dispose();
    },
  );
}
