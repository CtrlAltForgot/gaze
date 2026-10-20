import 'party/party_api.dart';
import 'party/party_controller.dart';
import 'party/party_playback_controller.dart';
import 'desktop/party_dialog.dart';
import 'desktop/party_links.dart';
import 'artists/public_artist_profile_provider.dart';
import 'design/gaze_motion.dart';
import 'lyrics/lrclib_lyrics_provider.dart';
import 'storage/local_content_cache.dart';
import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';

import 'application/jellyfin_playback_reporter.dart';
import 'application/playback_state_coordinator.dart';
import 'design/gaze_theme.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/linux_media_session.dart';
import 'desktop/linux_system_tray.dart';
import 'desktop/desktop_window.dart';
import 'desktop/window_chrome.dart';
import 'desktop/connect_screen.dart';
import 'connect/connect_controller.dart';
import 'connect/gaze_service_api.dart';
import 'jellyfin/flutter_secure_jellyfin_credential_store.dart';
import 'jellyfin/http_jellyfin_api.dart';
import 'jellyfin/jellyfin_api.dart';
import 'jellyfin/jellyfin_connection_controller.dart';
import 'playback/media_kit_playback_controller.dart';
import 'playback/fading_playback_controller.dart';
import 'playback/playback_controller.dart';
import 'playback/playback_queue_controller.dart';
import 'storage/playback_state_store.dart';
import 'storage/artwork_cache.dart';
import 'storage/artwork_palette_cache.dart';
import 'storage/file_artwork_cache.dart';
import 'storage/library_metadata_cache.dart';
import 'storage/sqlite_library_metadata_cache.dart';
import 'storage/sqlite_artwork_palette_cache.dart';
import 'storage/sqlite_playback_state_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final (
    playbackStateStore,
    artworkCache,
    metadataCache,
    paletteCache,
    contentCache,
  ) = await (
    _openStorage<PlaybackStateStore>(
      SqlitePlaybackStateStore.open,
      const DisabledPlaybackStateStore(),
    ),
    _openStorage<ArtworkCache>(
      FileArtworkCache.open,
      const DisabledArtworkCache(),
    ),
    _openStorage<LibraryMetadataCache>(
      SqliteLibraryMetadataCache.open,
      const DisabledLibraryMetadataCache(),
    ),
    _openStorage<ArtworkPaletteCache>(
      SqliteArtworkPaletteCache.open,
      const DisabledArtworkPaletteCache(),
    ),
    _openStorage<LocalContentCache>(
      SqliteLocalContentCache.open,
      const DisabledLocalContentCache(),
    ),
  ).wait;
  final credentialStore = const FlutterSecureJellyfinCredentialStore();
  final connectionController = JellyfinConnectionController(
    credentialStore: credentialStore,
    artworkCache: artworkCache,
    metadataCache: metadataCache,
    contentCache: contentCache,
    lyricsProvider: LrclibLyricsProvider(http.Client(), cache: contentCache),
    artistProfileProvider: !const bool.fromEnvironment('GAZE_ARTIST_PROFILES')
        ? null
        : PublicArtistProfileProvider(http.Client(), cache: contentCache),
    apiFactory: (deviceId) => HttpJellyfinApi(
      client: http.Client(),
      identity: JellyfinClientIdentity(deviceId: deviceId),
      artworkCache: artworkCache,
    ),
  );
  runApp(
    GazeApp(
      playbackController: FadingPlaybackController(
        MediaKitPlaybackController(),
      ),
      connectionController: connectionController,
      playbackStateStore: playbackStateStore,
      paletteCache: paletteCache,
      enableSystemMediaControls: true,
    ),
  );
  unawaited(connectionController.restore());
}

Future<T> _openStorage<T>(Future<T> Function() open, T fallback) async {
  try {
    return await open();
  } catch (_) {
    return fallback;
  }
}

class GazeApp extends StatefulWidget {
  const GazeApp({
    required this.playbackController,
    required this.connectionController,
    this.playbackStateStore = const DisabledPlaybackStateStore(),
    this.paletteCache = const DisabledArtworkPaletteCache(),
    this.enableSystemMediaControls = false,
    super.key,
  });

  final PlaybackController playbackController;
  final JellyfinConnectionController connectionController;
  final PlaybackStateStore playbackStateStore;
  final ArtworkPaletteCache paletteCache;
  final bool enableSystemMediaControls;

  @override
  State<GazeApp> createState() => _GazeAppState();
}

enum _DevelopmentScreen { shell, jellyfinConnection }

class _GazeAppState extends State<GazeApp> {
  _DevelopmentScreen _screen = _DevelopmentScreen.shell;
  bool _connectVisited = false;
  final _navigator = GlobalKey<NavigatorState>();
  final _partyLinks = PartyLinks();
  PartyController? _party;
  late final PlaybackController _playback = PartyPlaybackController(
    widget.playbackController,
    () => _party?.following == true,
    command: (action, data) async => _party?.command(action, data),
  );
  bool _inviteDialogOpen = false;
  Future<void> _openInvite(String link) async {
    try {
      PartyInvite.parse(link);
    } on PartyException {
      return;
    }
    if (_inviteDialogOpen || !mounted) return;
    final context = _navigator.currentContext;
    if (context == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInvite(link));
      return;
    }
    _inviteDialogOpen = true;
    await showPartyDialog(context, _party!, invite: link);
    _inviteDialogOpen = false;
  }

  late final PlaybackQueueController _queueController = PlaybackQueueController(
    playbackController: _playback,
  );
  late final ConnectController _connectController;
  late final JellyfinPlaybackReporter _playbackReporter;
  late final PlaybackStateCoordinator _playbackStateCoordinator;
  LinuxMediaSession? _mediaSession;
  LinuxSystemTray? _systemTray;
  final LinuxDesktopWindow _window = const LinuxDesktopWindow();
  Future<void>? _quitting;

  @override
  void initState() {
    super.initState();
    _connectController = ConnectController(
      connection: widget.connectionController,
      api: HttpGazeServiceApi(http.Client()),
    );
    _party = PartyController(
      api: HttpPartyApi(http.Client()),
      connect: _connectController,
      playback: widget.playbackController,
      queue: _queueController,
    );
    if (widget.enableSystemMediaControls)
      unawaited(_partyLinks.start(_openInvite));
    _playbackReporter = JellyfinPlaybackReporter(
      playbackController: _playback,
      connectionController: widget.connectionController,
    );
    _playbackStateCoordinator = PlaybackStateCoordinator(
      playbackController: _playback,
      queueController: _queueController,
      connectionController: widget.connectionController,
      store: widget.playbackStateStore,
      isFollowingParty: () => _party?.following == true,
    );
    if (widget.enableSystemMediaControls && Platform.isLinux) {
      _window.setQuitHandler(_quit);
      _systemTray = LinuxSystemTray(
        playback: _playback,
        queue: _queueController,
        bus: DBusClient.session(),
        window: _window,
        onQuit: _quit,
      );
      unawaited(
        _systemTray!.start().catchError((Object _) {
          debugPrint('gaze: system tray unavailable; closing minimizes.');
        }),
      );
      _mediaSession = LinuxMediaSession(
        playback: _playback,
        queue: _queueController,
        bus: DBusClient.session(),
      );
      unawaited(
        _mediaSession!.start().catchError((Object _) {
          debugPrint('gaze: system media controls unavailable.');
        }),
      );
    }
  }

  Future<void> _quit() => _quitting ??= _quitOnce().catchError((Object error) {
    _quitting = null;
    throw error;
  });

  Future<void> _quitOnce() async {
    // Save before stopping: Stop resets the engine position. Closing with X
    // never calls this path and therefore never interrupts music.
    await _party?.leave();
    await _playbackStateCoordinator.flush();
    await widget.playbackController.pause();
    await _playbackStateCoordinator.flush();
    await _window.quit();
  }

  @override
  void dispose() {
    if (widget.enableSystemMediaControls && Platform.isLinux) {
      _window.setQuitHandler(null);
    }
    _partyLinks.dispose();
    _party?.dispose();
    _connectController.dispose();
    unawaited(_playbackReporter.dispose());
    unawaited(_playbackStateCoordinator.dispose());
    unawaited(_disposePlayback());
    unawaited(widget.connectionController.dispose());
    super.dispose();
  }

  Future<void> _disposePlayback() async {
    await _systemTray?.dispose();
    await _mediaSession?.dispose();
    await _queueController.dispose();
    await widget.playbackController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'gaze',
      debugShowCheckedModeBanner: false,
      theme: buildGazeTheme(),
      builder: (context, child) =>
          Platform.isLinux && widget.enableSystemMediaControls
          ? DesktopWindowFrame(child: child!)
          : child!,
      home: GazePageStack(
        index: _screen == _DevelopmentScreen.shell ? 0 : 1,
        children: [
          DesktopShell(
            partyController: _party,
            connectionController: widget.connectionController,
            playbackController: _playback,
            queueController: _queueController,
            paletteCache: widget.paletteCache,
            onOpenJellyfinConnection: () => setState(() {
              _connectVisited = true;
              _screen = _DevelopmentScreen.jellyfinConnection;
            }),
          ),
          if (_connectVisited)
            ConnectScreen(
              controller: _connectController,
              onClose: () => setState(() => _screen = _DevelopmentScreen.shell),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}
