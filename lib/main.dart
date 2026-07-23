import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';

import 'application/jellyfin_playback_reporter.dart';
import 'application/playback_state_coordinator.dart';
import 'design/gaze_theme.dart';
import 'desktop/desktop_shell.dart';
import 'jellyfin/flutter_secure_jellyfin_credential_store.dart';
import 'jellyfin/http_jellyfin_api.dart';
import 'jellyfin/jellyfin_api.dart';
import 'jellyfin/jellyfin_connection_controller.dart';
import 'jellyfin/jellyfin_connection_screen.dart';
import 'playback/media_kit_playback_controller.dart';
import 'playback/playback_controller.dart';
import 'playback/playback_test_screen.dart';
import 'playback/playback_queue_controller.dart';
import 'storage/playback_state_store.dart';
import 'storage/artwork_cache.dart';
import 'storage/file_artwork_cache.dart';
import 'storage/library_metadata_cache.dart';
import 'storage/sqlite_library_metadata_cache.dart';
import 'storage/sqlite_playback_state_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  PlaybackStateStore playbackStateStore;
  ArtworkCache artworkCache;
  LibraryMetadataCache metadataCache;
  try {
    playbackStateStore = await SqlitePlaybackStateStore.open();
  } catch (_) {
    playbackStateStore = const DisabledPlaybackStateStore();
  }
  try {
    artworkCache = await FileArtworkCache.open();
  } catch (_) {
    artworkCache = const DisabledArtworkCache();
  }
  try {
    metadataCache = await SqliteLibraryMetadataCache.open();
  } catch (_) {
    metadataCache = const DisabledLibraryMetadataCache();
  }
  final credentialStore = const FlutterSecureJellyfinCredentialStore();
  final connectionController = JellyfinConnectionController(
    credentialStore: credentialStore,
    artworkCache: artworkCache,
    metadataCache: metadataCache,
    apiFactory: (deviceId) => HttpJellyfinApi(
      client: http.Client(),
      identity: JellyfinClientIdentity(deviceId: deviceId),
      artworkCache: artworkCache,
    ),
  );
  runApp(
    GazeApp(
      playbackController: MediaKitPlaybackController(),
      connectionController: connectionController,
      playbackStateStore: playbackStateStore,
    ),
  );
  unawaited(connectionController.restore());
}

class GazeApp extends StatefulWidget {
  const GazeApp({
    required this.playbackController,
    required this.connectionController,
    this.playbackStateStore = const DisabledPlaybackStateStore(),
    super.key,
  });

  final PlaybackController playbackController;
  final JellyfinConnectionController connectionController;
  final PlaybackStateStore playbackStateStore;

  @override
  State<GazeApp> createState() => _GazeAppState();
}

enum _DevelopmentScreen { shell, jellyfinConnection, playbackTest }

class _GazeAppState extends State<GazeApp> {
  _DevelopmentScreen _screen = _DevelopmentScreen.shell;
  late final PlaybackQueueController _queueController = PlaybackQueueController(
    playbackController: widget.playbackController,
  );
  late final JellyfinPlaybackReporter _playbackReporter;
  late final PlaybackStateCoordinator _playbackStateCoordinator;

  @override
  void initState() {
    super.initState();
    _playbackReporter = JellyfinPlaybackReporter(
      playbackController: widget.playbackController,
      connectionController: widget.connectionController,
    );
    _playbackStateCoordinator = PlaybackStateCoordinator(
      playbackController: widget.playbackController,
      queueController: _queueController,
      connectionController: widget.connectionController,
      store: widget.playbackStateStore,
    );
  }

  @override
  void dispose() {
    unawaited(_playbackReporter.dispose());
    unawaited(_playbackStateCoordinator.dispose());
    unawaited(_queueController.dispose());
    unawaited(widget.playbackController.dispose());
    unawaited(widget.connectionController.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'gaze',
      debugShowCheckedModeBanner: false,
      theme: buildGazeTheme(),
      home: switch (_screen) {
        _DevelopmentScreen.jellyfinConnection => JellyfinConnectionScreen(
          controller: widget.connectionController,
          onClose: () => setState(() => _screen = _DevelopmentScreen.shell),
        ),
        _DevelopmentScreen.playbackTest => PlaybackTestScreen(
          controller: widget.playbackController,
          onClose: () => setState(() => _screen = _DevelopmentScreen.shell),
        ),
        _DevelopmentScreen.shell => DesktopShell(
          connectionController: widget.connectionController,
          playbackController: widget.playbackController,
          queueController: _queueController,
          onOpenJellyfinConnection: () =>
              setState(() => _screen = _DevelopmentScreen.jellyfinConnection),
          onOpenPlaybackTest: () =>
              setState(() => _screen = _DevelopmentScreen.playbackTest),
        ),
      },
    );
  }
}
