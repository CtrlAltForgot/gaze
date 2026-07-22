import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';

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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final credentialStore = const FlutterSecureJellyfinCredentialStore();
  final connectionController = JellyfinConnectionController(
    credentialStore: credentialStore,
    apiFactory: (deviceId) => HttpJellyfinApi(
      client: http.Client(),
      identity: JellyfinClientIdentity(deviceId: deviceId),
    ),
  );
  runApp(
    GazeApp(
      playbackController: MediaKitPlaybackController(),
      connectionController: connectionController,
    ),
  );
}

class GazeApp extends StatefulWidget {
  const GazeApp({
    required this.playbackController,
    required this.connectionController,
    super.key,
  });

  final PlaybackController playbackController;
  final JellyfinConnectionController connectionController;

  @override
  State<GazeApp> createState() => _GazeAppState();
}

enum _DevelopmentScreen { shell, jellyfinConnection, playbackTest }

class _GazeAppState extends State<GazeApp> {
  _DevelopmentScreen _screen = _DevelopmentScreen.shell;

  @override
  void dispose() {
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
          onOpenJellyfinConnection: () =>
              setState(() => _screen = _DevelopmentScreen.jellyfinConnection),
          onOpenPlaybackTest: () =>
              setState(() => _screen = _DevelopmentScreen.playbackTest),
        ),
      },
    );
  }
}
