import '../party/party_controller.dart';
import 'party_listening_view.dart';
import 'artist_links.dart';
import '../design/gaze_motion.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import '../design/artwork_palette.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/album_summary.dart';
import '../library/playlist_summary.dart';
import '../library/library_search_results.dart';
import '../library/song_summary.dart';
import 'lyrics_view.dart';
import '../library/track_summary.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_queue_controller.dart';
import '../storage/artwork_palette_cache.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'smooth_scroll_controller.dart';
import 'track_selection.dart';
import 'songs_page.dart';
import 'playlists_page.dart';
import 'playback_controls.dart';
import 'media_mode.dart';
import 'marquee_text.dart';
import 'queue_panel.dart';
import 'song_row.dart';
import 'window_chrome.dart';

enum _LibraryDestination { home, albums, artists, songs, playlists }

class DesktopShell extends StatefulWidget {
  const DesktopShell({
    required this.connectionController,
    required this.playbackController,
    required this.queueController,
    required this.onOpenJellyfinConnection,
    this.partyController,
    this.paletteCache = const DisabledArtworkPaletteCache(),
    super.key,
  });

  final JellyfinConnectionController connectionController;
  final PlaybackController playbackController;
  final PlaybackQueueController queueController;
  final VoidCallback onOpenJellyfinConnection;
  final ArtworkPaletteCache paletteCache;
  final PartyController? partyController;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  List<AlbumSummary> _albums = const [];
  List<PlaylistSummary> _sidebarPlaylists = const [];
  PlaylistSummary? _openedPlaylist;
  String? _highlightedPlaylistId;
  int _playlistRequest = 0;
  int _playlistNavigationRevision = 0;
  String? _openedArtist;
  int _artistNavigationRevision = 0;
  int _albumRequest = 0;
  String? _account;
  String? _paletteItemId;
  final Set<_LibraryDestination> _visited = {_LibraryDestination.home};
  bool _loading = false;
  bool _offline = false;
  String? _error;
  StreamSubscription<JellyfinConnectionState>? _connectionSubscription;
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  _LibraryDestination _destination = _LibraryDestination.home;
  AlbumSummary? _albumOpenedFromHome;
  AlbumSummary? _retainedHomeAlbum;
  ArtworkPalette _palette = ArtworkPalette.fallback;
  Uint8List? _paletteArtwork;
  Timer? _searchDebounce;
  String _searchQuery = '';
  LibrarySearchResults? _searchResults;
  bool _searching = false;
  String? _searchError;
  int _searchRequest = 0;
  bool _lyricsVisible = false;
  bool _lyricsVisited = false;
  bool _mediaMode = false;
  bool _mediaModeVisited = false;
  bool _mediaMotion = true;
  bool _queueVisible = false;
  final SmoothScrollController _homeScrollController = SmoothScrollController();

  bool get _connected => widget.connectionController.state.canBrowseLibrary;

  @override
  void initState() {
    super.initState();
    widget.partyController?.addListener(_partyChanged);
    _account = widget.connectionController.accountKey;
    _offline =
        widget.connectionController.state.status ==
        JellyfinConnectionStatus.offline;
    _connectionSubscription = widget.connectionController.states.listen(
      _handleConnectionState,
    );
    _playbackSubscription = widget.playbackController.states.listen(
      _handlePlaybackState,
    );
    _handlePlaybackState(widget.playbackController.state);
    if (_connected) {
      _loadAlbums();
    }
    if (widget.connectionController.state.isConnected) {
      unawaited(_loadSidebarPlaylists());
    }
  }

  bool _partyWasActive = false;
  void _partyChanged() {
    final active = widget.partyController?.active == true;
    if (mounted && active != _partyWasActive) {
      setState(() {
        if (active) _queueVisible = true;
      });
    }
    _partyWasActive = active;
  }

  void _handleConnectionState(JellyfinConnectionState state) {
    if (!mounted) return;
    final account = widget.connectionController.accountKey;
    if (account != _account) {
      _account = account;
      _lyricsVisible = false;
      _lyricsVisited = false;
      _queueVisible = false;
      _albums = const [];
      _sidebarPlaylists = const [];
      _openedPlaylist = null;
      _highlightedPlaylistId = null;
      _playlistRequest++;
      _albumOpenedFromHome = null;
      _retainedHomeAlbum = null;
      _destination = _LibraryDestination.home;
      _visited
        ..clear()
        ..add(_LibraryDestination.home);
      _searchRequest++;
      _searchQuery = '';
      _searchResults = null;
      _searchError = null;
      _searching = false;
    }
    if (state.isConnected) unawaited(_loadSidebarPlaylists());
    if (state.canBrowseLibrary) {
      setState(
        () => _offline = state.status == JellyfinConnectionStatus.offline,
      );
      unawaited(_loadAlbums());
    } else {
      ++_albumRequest;
      setState(() {
        _albums = const [];
        _offline = false;
        _loading = state.status == JellyfinConnectionStatus.connecting;
        _error = state.errorMessage;
      });
    }
  }

  @override
  void dispose() {
    widget.partyController?.removeListener(_partyChanged);
    ++_albumRequest;
    ++_playlistRequest;
    unawaited(_connectionSubscription?.cancel());
    unawaited(_playbackSubscription?.cancel());
    _searchDebounce?.cancel();
    _homeScrollController.dispose();
    super.dispose();
  }

  Future<void> _handlePlaybackState(PlaybackSnapshot playback) async {
    final queue = widget.queueController.state;
    final source =
        queue.currentIndex >= 0 && queue.currentIndex < queue.items.length
        ? queue.items[queue.currentIndex]
        : null;
    if (_paletteItemId == playback.itemId &&
        (playback.artworkBytes == null ||
            identical(playback.artworkBytes, _paletteArtwork)))
      return;
    _paletteItemId = playback.itemId;
    final artwork =
        playback.artworkBytes ??
        await widget.connectionController.loadArtwork(
          source?.artworkId,
          source?.artworkTag,
        );
    if (!mounted ||
        _paletteItemId != playback.itemId ||
        artwork == null ||
        identical(artwork, _paletteArtwork)) {
      return;
    }
    _paletteArtwork = artwork;
    final fingerprint = fingerprintArtwork(artwork);
    ArtworkPalette? palette;
    try {
      final stored = await widget.paletteCache.read(fingerprint);
      if (stored != null) {
        palette = ArtworkPalette(
          accent: Color(stored.accentArgb),
          background: stored.backgroundArgb
              .map(Color.new)
              .toList(growable: false),
          backgroundWeights: stored.backgroundWeights,
        );
      }
    } catch (_) {
      // Palette persistence is an optimization, never a playback dependency.
    }
    final resolvedPalette = palette ?? await extractArtworkPalette(artwork);
    if (palette == null) {
      try {
        await widget.paletteCache.write(
          fingerprint,
          StoredArtworkPalette(
            accentArgb: resolvedPalette.accent.toARGB32(),
            backgroundArgb: resolvedPalette.background
                .map((color) => color.toARGB32())
                .toList(growable: false),
            backgroundWeights: resolvedPalette.backgroundWeights,
          ),
        );
      } catch (_) {
        // A calculated palette remains usable when persistence fails.
      }
    }
    if (mounted && identical(artwork, _paletteArtwork)) {
      setState(() => _palette = resolvedPalette);
    }
  }

  Future<void> _loadAlbums({bool forceRefresh = false}) async {
    final request = ++_albumRequest;
    bool active() => mounted && request == _albumRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await for (final page in widget.connectionController.watchAlbums(
        sort: AlbumSort.recentlyAdded,
        startIndex: 0,
        limit: 10,
        forceRefresh: forceRefresh,
      )) {
        if (!active()) return;
        setState(() => _albums = page.albums);
      }
    } on Exception catch (error) {
      if (active()) setState(() => _error = error.toString());
    } finally {
      if (active()) setState(() => _loading = false);
    }
  }

  Future<void> _loadSidebarPlaylists() async {
    final request = ++_playlistRequest;
    final account = widget.connectionController.accountKey;
    if (!widget.connectionController.state.isConnected) return;
    try {
      final page = await widget.connectionController.loadPlaylists(
        startIndex: 0,
        limit: 48,
      );
      if (!mounted ||
          request != _playlistRequest ||
          widget.connectionController.accountKey != account)
        return;
      setState(() {
        _sidebarPlaylists = page.playlists;
        // Keep the active details page; its own edit flow owns its new metadata.
      });
    } on Exception {
      // Sidebar shortcuts must never delay or replace the usable library.
    }
  }

  void _openSidebarPlaylist(PlaylistSummary playlist) {
    setState(() {
      _lyricsVisible = false;
      _openedPlaylist = playlist;
      _highlightedPlaylistId = playlist.id;
      _playlistNavigationRevision++;
      _albumOpenedFromHome = null;
      _destination = _LibraryDestination.playlists;
      _visited.add(_LibraryDestination.playlists);
    });
  }

  int _playlistPlayRequest = 0;
  Future<void> _playSidebarPlaylist(PlaylistSummary playlist) async {
    final request = ++_playlistPlayRequest;
    final account = widget.connectionController.accountKey;
    _openSidebarPlaylist(playlist);
    try {
      List<SongSummary> songs = [];
      await for (final page in widget.connectionController.loadPlaylistTracks(
        playlist.id,
        isCancelled: () =>
            !mounted ||
            request != _playlistPlayRequest ||
            widget.connectionController.accountKey != account,
      )) {
        songs = page.songs;
      }
      if (!mounted ||
          request != _playlistPlayRequest ||
          widget.connectionController.accountKey != account)
        return;
      await _playSongs(songs, null);
    } on Exception catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _retryConnection() async {
    if (widget.connectionController.state.isConnected) {
      await _loadAlbums(forceRefresh: true);
    } else {
      await widget.connectionController.reconnect();
    }
  }

  void _openAlbum(AlbumSummary album) {
    setState(() {
      _lyricsVisible = false;
      _albumOpenedFromHome = album;
      _retainedHomeAlbum = album;
    });
  }

  void _handleSearchChanged(String value) {
    final query = value.trim();
    _searchDebounce?.cancel();
    if (query.isEmpty) {
      _searchRequest++;
      setState(() {
        _searchQuery = '';
        _searchResults = null;
        _searching = false;
        _searchError = null;
      });
      return;
    }
    setState(() {
      _searchQuery = query;
      _searching = true;
      _searchError = null;
    });
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(query),
    );
  }

  Future<void> _search(String query) async {
    final request = ++_searchRequest;
    try {
      final results = await widget.connectionController.searchLibrary(query);
      if (mounted && request == _searchRequest) {
        setState(() {
          _searchResults = results;
          _searching = false;
        });
      }
    } on Exception catch (error) {
      if (mounted && request == _searchRequest) {
        setState(() {
          _searchResults = null;
          _searching = false;
          _searchError = error.toString();
        });
      }
    }
  }

  Future<void> _playSearchTrack(TrackSearchResult result) {
    final stream = widget.connectionController.createDirectPlaySource(
      result.track.id,
    );
    return widget.queueController.playAlbum([
      RemotePlaybackSource(
        uri: stream.uri,
        headers: stream.headers,
        title: result.track.title,
        artist: result.track.artist,
        itemId: result.track.id,
        artworkBytes:
            result.artworkBytes ??
            widget.connectionController.peekArtwork(
              result.albumId,
              result.imageTag,
            ),
        artworkId: result.albumId,
        artworkTag: result.imageTag,
      ),
    ], startIndex: 0);
  }

  Future<void> _playAlbum(
    AlbumSummary album,
    List<TrackSummary> tracks,
    int startIndex,
  ) {
    final sources = tracks
        .map((track) {
          final jellyfinSource = widget.connectionController
              .createDirectPlaySource(track.id);
          return RemotePlaybackSource(
            uri: jellyfinSource.uri,
            headers: jellyfinSource.headers,
            title: track.title,
            artist: track.artist,
            itemId: track.id,
            artworkBytes:
                album.artworkBytes ??
                widget.connectionController.peekArtwork(
                  album.id,
                  album.imageTag,
                ),
            artworkId: album.id,
            artworkTag: album.imageTag,
          );
        })
        .toList(growable: false);
    return widget.queueController.playAlbum(sources, startIndex: startIndex);
  }

  Future<void> _queueSongs(List<SongSummary> songs, bool next) async {
    if (!widget.connectionController.state.isConnected) return;
    final sources = songs
        .map((song) {
          final stream = widget.connectionController.createDirectPlaySource(
            song.track.id,
          );
          return RemotePlaybackSource(
            uri: stream.uri,
            headers: stream.headers,
            title: song.track.title,
            artist: song.track.artist,
            itemId: song.track.id,
            artworkBytes: song.artworkBytes,
            artworkId: song.albumId,
            artworkTag: song.imageTag,
          );
        })
        .toList(growable: false);
    await widget.queueController.enqueue(sources, next: next);
    if (mounted)
      setState(() {
        _queueVisible = true;
      });
  }

  Widget _queuePanel() => QueuePanel(
    partyController: widget.partyController,
    connectionController: widget.connectionController,
    controller: widget.queueController,
    online: widget.connectionController.state.isConnected,
    onClose: () => setState(() => _queueVisible = false),
  );

  Widget _lyrics({bool immersive = false}) => LyricsView(
    key: ValueKey(_account),
    immersive: immersive,
    connectionController: widget.connectionController,
    playbackController: widget.playbackController,
    onClose: () => setState(() => _lyricsVisible = false),
  );

  void _toggleLyrics() => setState(() {
    _lyricsVisible = !_lyricsVisible;
    if (_lyricsVisible) _lyricsVisited = true;
  });

  Widget _centerContent() => GazePageStack(
    index: _lyricsVisible ? 1 : 0,
    children: [
      widget.partyController?.following == true &&
              _destination == _LibraryDestination.home
          ? PartyListeningView(party: widget.partyController!)
          : _libraryContent(),
      if (_lyricsVisited) _lyrics(),
    ],
  );

  Future<void> _playSongs(List<SongSummary> songs, int? startIndex) {
    final sources = songs
        .map((song) {
          final jellyfinSource = widget.connectionController
              .createDirectPlaySource(song.track.id);
          return RemotePlaybackSource(
            uri: jellyfinSource.uri,
            headers: jellyfinSource.headers,
            title: song.track.title,
            artist: song.track.artist,
            itemId: song.track.id,
            artworkBytes: song.artworkBytes,
            artworkId: song.albumId,
            artworkTag: song.imageTag,
          );
        })
        .toList(growable: false);
    return startIndex == null
        ? widget.queueController.playCollection(sources)
        : widget.queueController.playAlbum(sources, startIndex: startIndex);
  }

  void _openArtist(String name) => setState(() {
    _openedArtist = name;
    _artistNavigationRevision++;
    _destination = _LibraryDestination.artists;
    _visited.add(_destination);
    _albumOpenedFromHome = null;
    _mediaMode = false;
    _lyricsVisible = false;
  });

  Widget _libraryContent() => GazePageStack(
    key: ValueKey(_account),
    index: _albumOpenedFromHome == null
        ? _destination.index
        : _LibraryDestination.values.length,
    children: [
      for (final destination in _LibraryDestination.values)
        TickerMode(
          enabled: destination == _destination && _albumOpenedFromHome == null,
          child: _visited.contains(destination)
              ? _destinationPage(destination)
              : const SizedBox.shrink(),
        ),
      if (_retainedHomeAlbum != null)
        AlbumsPage(
          key: ValueKey(_retainedHomeAlbum!.id),
          connectionController: widget.connectionController,
          onConnect: widget.onOpenJellyfinConnection,
          onPlayTrack: _playAlbum,
          initialAlbum: _retainedHomeAlbum,
          initialAlbumBackLabel: 'Home',
          onInitialAlbumBack: () => setState(() => _albumOpenedFromHome = null),
        ),
    ],
  );

  Widget _destinationPage(_LibraryDestination destination) =>
      switch (destination) {
        _LibraryDestination.home => _HomeContent(
          connectionController: widget.connectionController,
          connected: _connected,
          loading: _loading,
          offline: _offline,
          albums: _albums,
          error: _error,
          onConnect: widget.onOpenJellyfinConnection,
          onRetry: _retryConnection,
          onOpenAlbum: _openAlbum,
          searchQuery: _searchQuery,
          searchResults: _searchResults,
          searching: _searching,
          searchError: _searchError,
          onSearchChanged: _handleSearchChanged,
          onPlaySearchTrack: _playSearchTrack,
          scrollController: _homeScrollController,
        ),
        _LibraryDestination.albums => AlbumsPage(
          connectionController: widget.connectionController,
          onConnect: widget.onOpenJellyfinConnection,
          onPlayTrack: _playAlbum,
        ),
        _LibraryDestination.artists => ArtistsPage(
          initialArtist: _openedArtist,
          navigationRevision: _artistNavigationRevision,
          onPlaySongs: _playSongs,
          connectionController: widget.connectionController,
          onConnect: widget.onOpenJellyfinConnection,
          onPlayTrack: _playAlbum,
        ),
        _LibraryDestination.songs => SongsPage(
          connectionController: widget.connectionController,
          onConnect: widget.onOpenJellyfinConnection,
          onPlaySongs: _playSongs,
          onQueueSong: (song, next) => _queueSongs([song], next),
        ),
        _LibraryDestination.playlists => PlaylistsPage(
          initialPlaylist: _openedPlaylist,
          navigationRevision: _playlistNavigationRevision,
          onPlaylistsChanged: () => unawaited(_loadSidebarPlaylists()),
          onSelectionChanged: (playlist) {
            if (mounted && _highlightedPlaylistId != playlist?.id) {
              setState(() => _highlightedPlaylistId = playlist?.id);
            }
          },
          connectionController: widget.connectionController,
          onConnect: widget.onOpenJellyfinConnection,
          onPlaySongs: _playSongs,
          onQueueSongs: _queueSongs,
          onPlayPlaylist: (songs) => _playSongs(songs, null),
        ),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _homeScrollController.smoothingEnabled = !MediaQuery.disableAnimationsOf(
      context,
    );
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(primary: _palette.accent),
        sliderTheme: theme.sliderTheme.copyWith(
          activeTrackColor: _palette.accent,
          thumbColor: _palette.accent,
        ),
        focusColor: _palette.accent.withValues(alpha: .24),
      ),
      child: ArtistNavigationScope(
        onOpenArtist: _openArtist,
        child: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 900),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _AmbientArtworkBackground(
                    key: ValueKey(
                      _palette.background
                          .map((color) => color.toARGB32())
                          .join(),
                    ),
                    colors: _palette.background,
                    weights: _palette.backgroundWeights,
                    animate:
                        _mediaMode &&
                        _mediaMotion &&
                        _paletteArtwork != null &&
                        !MediaQuery.disableAnimationsOf(context),
                  ),
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compactNavigation = constraints.maxWidth < 920;
                  final navigationWidth = compactNavigation
                      ? 80.0
                      : constraints.maxWidth >= 1180
                      ? 264.0
                      : 224.0;
                  final panelOpen = _queueVisible;
                  // Lyrics and queue stay side by side even in a compact window.
                  final panelInline =
                      _lyricsVisible || constraints.maxWidth >= 1180;
                  final panelWidth = constraints.maxWidth >= 1700
                      ? 430.0
                      : constraints.maxWidth >= 1250
                      ? 360.0
                      : 320.0;
                  final library = Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _Navigation(
                                  compact: compactNavigation,
                                  width: navigationWidth,
                                  connectionController:
                                      widget.connectionController,
                                  playlists: _sidebarPlaylists,
                                  openedPlaylistId:
                                      _destination ==
                                          _LibraryDestination.playlists
                                      ? _highlightedPlaylistId
                                      : null,
                                  onOpenPlaylist: _openSidebarPlaylist,
                                  onPlayPlaylist: _playSidebarPlaylist,
                                  destination: _destination,
                                  onDestinationChanged: (destination) =>
                                      setState(() {
                                        _lyricsVisible = false;
                                        _albumOpenedFromHome = null;
                                        if (destination ==
                                            _LibraryDestination.playlists) {
                                          _openedPlaylist = null;
                                          _playlistNavigationRevision++;
                                        }
                                        _destination = destination;
                                        _visited.add(destination);
                                      }),
                                  onOpenJellyfinConnection:
                                      widget.onOpenJellyfinConnection,
                                ),
                                VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: Colors.white.withValues(alpha: .16),
                                ),
                                Expanded(child: _centerContent()),
                                if (panelInline)
                                  GazePanel(
                                    open: panelOpen,
                                    width: panelWidth + 1,
                                    child: panelOpen
                                        ? Row(
                                            children: [
                                              VerticalDivider(
                                                width: 1,
                                                color: Colors.white.withValues(
                                                  alpha: .16,
                                                ),
                                              ),
                                              Expanded(child: _queuePanel()),
                                            ],
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                            if (!panelInline) ...[
                              Positioned.fill(
                                left: navigationWidth,
                                child: IgnorePointer(
                                  ignoring: !panelOpen,
                                  child: AnimatedOpacity(
                                    opacity: panelOpen ? 1 : 0,
                                    duration: GazeMotion.duration(context),
                                    child: GestureDetector(
                                      onTap: () =>
                                          setState(() => _queueVisible = false),
                                      child: ColoredBox(
                                        color: Colors.black.withValues(
                                          alpha: .35,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 0,
                                right: 0,
                                bottom: 0,
                                width: math.min(
                                  panelWidth,
                                  constraints.maxWidth - navigationWidth - 1,
                                ),
                                child: GazePanel(
                                  open: panelOpen,
                                  width: math.min(
                                    panelWidth,
                                    constraints.maxWidth - navigationWidth - 1,
                                  ),
                                  child: panelOpen ? _queuePanel() : null,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      _PlayerBar(
                        onMediaMode: () => setState(() {
                          _mediaMode = true;
                          _mediaModeVisited = true;
                        }),
                        connectionController: widget.connectionController,
                        controller: widget.playbackController,
                        queueController: widget.queueController,
                        lyricsVisible: _lyricsVisible,
                        onToggleLyrics: _toggleLyrics,
                        queueVisible: _queueVisible,
                        onToggleQueue: () => setState(() {
                          _queueVisible = !_queueVisible;
                        }),
                      ),
                    ],
                  );
                  return GazePageStack(
                    vertical: true,
                    index: _mediaMode ? 1 : 0,
                    children: [
                      TickerMode(enabled: !_mediaMode, child: library),
                      if (_mediaModeVisited)
                        MediaMode(
                          active: _mediaMode,
                          connection: widget.connectionController,
                          playback: widget.playbackController,
                          queue: widget.queueController,
                          onClose: () => setState(() => _mediaMode = false),
                          motionEnabled: _mediaMotion,
                          onToggleMotion: () =>
                              setState(() => _mediaMotion = !_mediaMotion),
                          onLyrics: _toggleLyrics,
                          lyrics: _lyricsVisible
                              ? _lyrics(immersive: true)
                              : null,
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AmbientArtworkBackground extends StatefulWidget {
  const _AmbientArtworkBackground({
    required this.colors,
    required this.weights,
    required this.animate,
    super.key,
  });

  final List<Color> colors;
  final List<double> weights;
  final bool animate;

  @override
  State<_AmbientArtworkBackground> createState() =>
      _AmbientArtworkBackgroundState();
}

class _AmbientArtworkBackgroundState extends State<_AmbientArtworkBackground>
    with WidgetsBindingObserver {
  final ValueNotifier<double> _controller = ValueNotifier(.18);
  Timer? _timer;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(_AmbientArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateMotion();
  }

  void _updateMotion() {
    _timer?.cancel();
    // Slow atmosphere needs only 20 updates/second, independent of display Hz.
    // The library stays static; only Media Mode opts in to this cheap painter.
    if (widget.animate && _foreground && TickerMode.valuesOf(context).enabled) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        _controller.value = (_controller.value + 50 / 36000) % 1;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _AmbientArtworkPainter(
          colors: widget.colors,
          weights: widget.weights,
          motion: _controller,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _AmbientArtworkPainter extends CustomPainter {
  _AmbientArtworkPainter({
    required this.colors,
    required this.weights,
    required this.motion,
  }) : super(repaint: motion);

  final List<Color> colors;
  final List<double> weights;
  final ValueNotifier<double> motion;

  @override
  void paint(Canvas canvas, Size size) {
    var dominantIndex = 0;
    for (var index = 1; index < weights.length; index++) {
      if (weights[index] > weights[dominantIndex]) {
        dominantIndex = index;
      }
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = colors[dominantIndex]);
    final phase = motion.value * math.pi * 2;
    final shortest = math.min(size.width, size.height);
    final blobs = [
      (
        center: Offset(
          size.width * (.18 + .1 * math.sin(phase)),
          size.height * (.2 + .12 * math.cos(phase * .83)),
        ),
        radius: math.max(shortest * .85, size.width * .42),
      ),
      (
        center: Offset(
          size.width * (.76 + .11 * math.cos(phase * .71)),
          size.height * (.28 + .14 * math.sin(phase * .91)),
        ),
        radius: math.max(shortest * .72, size.width * .36),
      ),
      (
        center: Offset(
          size.width * (.55 + .14 * math.sin(phase * .61 + 2)),
          size.height * (.82 + .1 * math.cos(phase * .77 + 1)),
        ),
        radius: math.max(shortest * .8, size.width * .4),
      ),
    ];
    for (var index = 0; index < blobs.length; index++) {
      final blob = blobs[index];
      final color = colors[index % colors.length];
      final weight = weights[index % weights.length].clamp(.01, 1);
      final scale = math.sqrt(weight / .25).clamp(.28, 1.45);
      final radius = blob.radius * scale;
      final centerOpacity = (.38 + weight * 1.35).clamp(.4, .94);
      canvas.drawCircle(
        blob.center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: centerOpacity),
              color.withValues(alpha: centerOpacity * .46),
              color.withValues(alpha: 0),
            ],
            stops: const [0, .48, 1],
          ).createShader(Rect.fromCircle(center: blob.center, radius: radius)),
      );
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x18000000),
    );
  }

  @override
  bool shouldRepaint(_AmbientArtworkPainter oldDelegate) =>
      oldDelegate.colors != colors || oldDelegate.weights != weights;
}

class _Navigation extends StatelessWidget {
  const _Navigation({
    required this.compact,
    required this.width,
    required this.connectionController,
    required this.playlists,
    required this.openedPlaylistId,
    required this.onOpenPlaylist,
    required this.onPlayPlaylist,
    required this.destination,
    required this.onDestinationChanged,
    required this.onOpenJellyfinConnection,
  });

  final bool compact;
  final double width;
  final JellyfinConnectionController connectionController;
  final List<PlaylistSummary> playlists;
  final String? openedPlaylistId;
  final ValueChanged<PlaylistSummary> onOpenPlaylist;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;
  final _LibraryDestination destination;
  final ValueChanged<_LibraryDestination> onDestinationChanged;
  final VoidCallback onOpenJellyfinConnection;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: GazeColors.navigation.withValues(alpha: .68),
    child: SizedBox(
      width: width,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? GazeSpacing.small : GazeSpacing.medium,
          vertical: GazeSpacing.medium,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!WindowFrameScope.activeOf(context))
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: GazeSpacing.small,
                  vertical: GazeSpacing.medium,
                ),
                child: Text(
                  compact ? 'g' : 'gaze',
                  textAlign: compact ? TextAlign.center : TextAlign.left,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            if (!WindowFrameScope.activeOf(context))
              const SizedBox(height: GazeSpacing.medium),
            Expanded(
              child: ListView(
                primary: false,
                padding: EdgeInsets.zero,
                children: [
                  for (final item in [
                    (_LibraryDestination.home, Icons.home_rounded, 'Home'),
                    (
                      _LibraryDestination.albums,
                      Icons.album_outlined,
                      'Albums',
                    ),
                    (
                      _LibraryDestination.artists,
                      Icons.people_outline_rounded,
                      'Artists',
                    ),
                    (
                      _LibraryDestination.songs,
                      Icons.music_note_rounded,
                      'Songs',
                    ),
                    (
                      _LibraryDestination.playlists,
                      Icons.queue_music_rounded,
                      'Playlists',
                    ),
                  ])
                    _NavigationItem(
                      icon: item.$2,
                      label: item.$3,
                      compact: compact,
                      selected: destination == item.$1,
                      onTap: () => onDestinationChanged(item.$1),
                    ),
                  if (!compact && playlists.isNotEmpty) ...[
                    const SizedBox(height: GazeSpacing.medium),
                    Divider(color: Colors.white.withValues(alpha: .10)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
                      child: Text(
                        'Your playlists',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: GazeColors.textSecondary,
                        ),
                      ),
                    ),
                    for (final playlist in playlists)
                      _PlaylistShortcut(
                        playlist: playlist,
                        connectionController: connectionController,
                        selected: openedPlaylistId == playlist.id,
                        onDoubleTap: connectionController.state.isConnected
                            ? () => onPlayPlaylist(playlist)
                            : null,
                        onTap: connectionController.state.isConnected
                            ? () => onOpenPlaylist(playlist)
                            : null,
                      ),
                    TextButton(
                      onPressed: () =>
                          onDestinationChanged(_LibraryDestination.playlists),
                      child: const Text('View all playlists'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: GazeSpacing.small),
            Tooltip(
              message: compact ? 'Connections' : '',
              child: TextButton.icon(
                onPressed: onOpenJellyfinConnection,
                icon: const Icon(Icons.cloud_outlined),
                label: compact
                    ? const SizedBox.shrink()
                    : const Text('Connect'),
                style: TextButton.styleFrom(
                  alignment: compact ? Alignment.center : Alignment.centerLeft,
                  foregroundColor: GazeColors.textSecondary,
                  minimumSize: const Size(48, 48),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PlaylistShortcut extends StatelessWidget {
  const _PlaylistShortcut({
    required this.playlist,
    required this.connectionController,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
  });
  final PlaylistSummary playlist;
  final JellyfinConnectionController connectionController;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Semantics(
      selected: selected,
      button: true,
      enabled: onTap != null,
      child: Material(
        animationDuration: GazeMotion.duration(context, GazeMotion.feedback),
        color: selected
            ? Colors.white.withValues(alpha: .09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(GazeRadii.control),
        child: InkWell(
          key: ValueKey('sidebar-playlist-${playlist.id}'),
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          borderRadius: BorderRadius.circular(GazeRadii.control),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                LibraryArtwork(
                  connectionController: connectionController,
                  itemId: playlist.id,
                  imageTag: playlist.imageTag,
                  dimension: 38,
                  icon: Icons.queue_music_rounded,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarqueeText(
                        playlist.title,
                        hoverOnly: true,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        playlist.trackCount == null
                            ? 'Playlist'
                            : '${playlist.trackCount} songs',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: GazeColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.compact,
    this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool compact;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? GazeColors.textPrimary
        : GazeColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: GazeSpacing.xSmall),
      child: Semantics(
        selected: selected,
        button: true,
        enabled: onTap != null,
        label: label,
        child: Material(
          animationDuration: GazeMotion.duration(context, GazeMotion.feedback),
          color: selected
              ? Colors.white.withValues(alpha: .075)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GazeRadii.control),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(GazeRadii.control),
            child: SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  if (!compact) const SizedBox(width: GazeSpacing.medium),
                  Icon(icon, color: foreground, size: 21),
                  if (!compact) ...[
                    const SizedBox(width: GazeSpacing.medium),
                    Text(
                      label,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({
    required this.connectionController,
    required this.connected,
    required this.loading,
    required this.offline,
    required this.albums,
    required this.error,
    required this.onConnect,
    required this.onRetry,
    required this.onOpenAlbum,
    required this.searchQuery,
    required this.searchResults,
    required this.searching,
    required this.searchError,
    required this.onSearchChanged,
    required this.onPlaySearchTrack,
    required this.scrollController,
  });

  final JellyfinConnectionController connectionController;
  final bool connected;
  final bool loading;
  final bool offline;
  final List<AlbumSummary> albums;
  final String? error;
  final VoidCallback onConnect;
  final VoidCallback onRetry;
  final ValueChanged<AlbumSummary> onOpenAlbum;
  final String searchQuery;
  final LibrarySearchResults? searchResults;
  final bool searching;
  final String? searchError;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<TrackSearchResult> onPlaySearchTrack;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) =>
      TrackSelectionScope(child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GazeSpacing.xLarge,
            GazeSpacing.large,
            GazeSpacing.xLarge,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final heading = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your music, brought forward.',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: GazeSpacing.small),
                    const Text(
                      'A calm place for the albums you chose to keep.',
                    ),
                  ],
                );
                final search = ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth < 700
                        ? constraints.maxWidth
                        : 320,
                  ),
                  child: TextFormField(
                    initialValue: searchQuery,
                    onChanged: onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search albums and songs',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: GazeColors.surface.withValues(alpha: .38),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(GazeRadii.control),
                        ),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                );
                if (constraints.maxWidth < 700) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      heading,
                      const SizedBox(height: GazeSpacing.large),
                      search,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: heading),
                    const SizedBox(width: GazeSpacing.large),
                    search,
                  ],
                );
              },
            ),
          ),
        ),
        if (offline)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              0,
              GazeSpacing.xLarge,
              GazeSpacing.medium,
            ),
            sliver: SliverToBoxAdapter(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .07),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .14),
                  ),
                  borderRadius: BorderRadius.circular(GazeRadii.control),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(GazeSpacing.medium),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 18),
                      const SizedBox(width: GazeSpacing.small),
                      const Expanded(
                        child: Text(
                          'Offline — showing music saved on this device. Streaming is unavailable.',
                        ),
                      ),
                      TextButton(
                        onPressed: onRetry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (searchQuery.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              GazeSpacing.xLarge,
              GazeSpacing.xLarge,
              GazeSpacing.medium,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Search results',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ),
        if (searchQuery.isNotEmpty && searching)
          const SliverPadding(
            padding: EdgeInsets.symmetric(vertical: GazeSpacing.xxLarge),
            sliver: SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (searchQuery.isNotEmpty && searchError != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LibraryMessage(
              icon: Icons.search_off_rounded,
              title: 'Search could not be completed',
              message: searchError!,
            ),
          )
        else if (searchQuery.isNotEmpty &&
            searchResults != null &&
            searchResults!.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LibraryMessage(
              icon: Icons.search_off_rounded,
              title: 'No matches found',
              message: 'No albums or songs matched “$searchQuery”.',
            ),
          ),
        if (searchQuery.isNotEmpty &&
            !searching &&
            searchError == null &&
            searchResults != null &&
            searchResults!.albums.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              GazeSpacing.medium,
              GazeSpacing.xLarge,
              GazeSpacing.small,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Albums',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
        if (searchQuery.isNotEmpty &&
            !searching &&
            searchError == null &&
            searchResults != null &&
            searchResults!.albums.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              0,
              GazeSpacing.xLarge,
              GazeSpacing.large,
            ),
            sliver: SliverGrid.builder(
              itemCount: searchResults!.albums.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 230,
                crossAxisSpacing: GazeSpacing.large,
                mainAxisSpacing: GazeSpacing.large,
                childAspectRatio: .78,
              ),
              itemBuilder: (context, index) {
                final album = searchResults!.albums[index];
                return _AlbumCard(
                  connectionController: connectionController,
                  album: album,
                  onTap: () => onOpenAlbum(album),
                );
              },
            ),
          ),
        if (searchQuery.isNotEmpty &&
            !searching &&
            searchError == null &&
            searchResults != null &&
            searchResults!.tracks.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              GazeSpacing.medium,
              GazeSpacing.xLarge,
              GazeSpacing.small,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Songs',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
        if (searchQuery.isNotEmpty &&
            !searching &&
            searchError == null &&
            searchResults != null &&
            searchResults!.tracks.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              0,
              GazeSpacing.xLarge,
              GazeSpacing.xLarge,
            ),
            sliver: SliverList.separated(
              itemCount: searchResults!.tracks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final result = searchResults!.tracks[index];
                return SongRow(
                  key: ValueKey('search:${result.track.id}:$index'),
                  song: SongSummary(
                    track: result.track,
                    album: '',
                    albumId: result.albumId,
                    imageTag: result.imageTag,
                    artworkBytes: result.artworkBytes,
                  ),
                  connectionController: connectionController,
                  showAlbum: false,
                  onPlay: connected ? (_) => onPlaySearchTrack(result) : null,
                );
              },
            ),
          ),
        if (searchQuery.isEmpty &&
            albums.isEmpty &&
            (loading ||
                connectionController.state.status ==
                    JellyfinConnectionStatus.restoring))
          const SliverPadding(
            padding: EdgeInsets.symmetric(vertical: GazeSpacing.xxLarge),
            sliver: SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (searchQuery.isEmpty && !connected)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LibraryMessage(
              icon: Icons.cloud_outlined,
              title: 'Connect your Jellyfin library',
              message: 'Your recently added albums will appear here.',
              buttonLabel: 'Connect',
              onPressed: onConnect,
            ),
          )
        else if (searchQuery.isEmpty && error != null && albums.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LibraryMessage(
              icon: Icons.cloud_off_outlined,
              title: 'Your library could not be loaded',
              message: error!,
              buttonLabel: 'Try again',
              onPressed: onRetry,
            ),
          )
        else if (searchQuery.isEmpty && albums.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _LibraryMessage(
              icon: Icons.album_outlined,
              title: 'No albums found',
              message:
                  'gaze connected successfully, but Jellyfin returned no music albums.',
            ),
          ),
        if (searchQuery.isEmpty && connected && albums.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              GazeSpacing.xxLarge,
              GazeSpacing.xLarge,
              GazeSpacing.medium,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Recently added',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ),
        if (searchQuery.isEmpty && connected && albums.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              0,
              GazeSpacing.xLarge,
              GazeSpacing.xLarge,
            ),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                return SliverGrid.builder(
                  itemCount: albums.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 270,
                    crossAxisSpacing: GazeSpacing.large,
                    mainAxisSpacing: GazeSpacing.xLarge,
                    childAspectRatio: 0.78,
                  ),
                  itemBuilder: (context, index) => _AlbumCard(
                    connectionController: connectionController,
                    album: albums[index],
                    onTap: () => onOpenAlbum(albums[index]),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.onTap,
    required this.connectionController,
  });

  final JellyfinConnectionController connectionController;

  final AlbumSummary album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${album.title} by ${album.artist}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(GazeRadii.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(GazeRadii.card),
                    color: GazeColors.surfaceRaised,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x55000000),
                        blurRadius: 22,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(GazeRadii.card),
                    child: LibraryArtwork(
                      connectionController: connectionController,
                      bytes: album.artworkBytes,
                      itemId: album.id,
                      imageTag: album.imageTag,
                      dimension: double.infinity,
                      icon: Icons.album_rounded,
                      iconSize: 52,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: GazeSpacing.medium),
            MarqueeText(
              album.title,
              hoverOnly: true,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: GazeSpacing.xSmall),
            ArtistLinks(album.artist, hoverOnly: true),
          ],
        ),
      ),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.connectionController,
    required this.controller,
    required this.queueController,
    required this.lyricsVisible,
    required this.onToggleLyrics,
    required this.queueVisible,
    required this.onToggleQueue,
    required this.onMediaMode,
  });

  final JellyfinConnectionController connectionController;
  final PlaybackController controller;
  final PlaybackQueueController queueController;
  final bool lyricsVisible;
  final bool queueVisible;
  final VoidCallback onToggleQueue;
  final VoidCallback onToggleLyrics;
  final VoidCallback onMediaMode;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackQueueState>(
      stream: queueController.states,
      initialData: queueController.state,
      builder: (context, queueSnapshot) => StreamBuilder<PlaybackSnapshot>(
        stream: controller.states,
        initialData: controller.state,
        builder: (context, snapshot) {
          final playback = snapshot.data ?? controller.state;
          final queue = queueSnapshot.data ?? queueController.state;
          final hasTrack = playback.title != null;
          final playing =
              playback.status == PlaybackStatus.playing ||
              playback.status == PlaybackStatus.buffering;
          final durationMs = playback.duration.inMilliseconds;
          final positionMs = playback.position.inMilliseconds.clamp(
            0,
            durationMs > 0 ? durationMs : 1,
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 900;
              final wide = constraints.maxWidth >= 1500;
              final artworkSize = compact ? 52.0 : 60.0;
              final metadataWidth = compact
                  ? 130.0
                  : wide
                  ? 240.0
                  : 180.0;
              final timelineWidth = compact
                  ? 400.0
                  : wide
                  ? 760.0
                  : 560.0;
              return Container(
                height: 88,
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? GazeSpacing.small : GazeSpacing.large,
                ),
                decoration: BoxDecoration(
                  color: GazeColors.navigation.withValues(alpha: .52),
                  border: Border(
                    top: BorderSide(color: Colors.white.withValues(alpha: .16)),
                  ),
                ),
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Row(
                    children: [
                      MediaModeArtwork(
                        onExpand: hasTrack ? onMediaMode : null,
                        child: LibraryArtwork(
                          connectionController: connectionController,
                          dimension: artworkSize,
                          bytes: playback.artworkBytes,
                          itemId: queue.currentIndex >= 0
                              ? queue.items[queue.currentIndex].artworkId
                              : null,
                          imageTag: queue.currentIndex >= 0
                              ? queue.items[queue.currentIndex].artworkTag
                              : null,
                        ),
                      ),
                      SizedBox(
                        width: compact ? GazeSpacing.small : GazeSpacing.medium,
                      ),
                      SizedBox(
                        width: metadataWidth,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MarqueeText(
                              playback.title ?? 'Nothing playing',
                              style: const TextStyle(
                                color: GazeColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: GazeSpacing.xSmall),
                            playback.errorMessage == null &&
                                    playback.artist?.isNotEmpty == true
                                ? ArtistLinks(playback.artist!)
                                : MarqueeText(
                                    playback.errorMessage != null
                                        ? playback.errorMessage!
                                        : playback.artist?.isNotEmpty == true
                                        ? playback.artist!
                                        : 'Choose a track from an album.',
                                  ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            PlaybackControls(
                              playing: playing,
                              shuffleEnabled: queue.shuffleEnabled,
                              repeatMode: queue.repeatMode,
                              onShuffle: () => queueController.setShuffle(
                                !queue.shuffleEnabled,
                              ),
                              onPrevious:
                                  queue.hasPrevious ||
                                      (hasTrack &&
                                          playback.position >
                                              PlaybackQueueController
                                                  .previousRestartThreshold)
                                  ? queueController.previous
                                  : null,
                              onPlayPause: hasTrack
                                  ? playing
                                        ? controller.pause
                                        : controller.play
                                  : null,
                              onNext: queue.hasNext
                                  ? queueController.next
                                  : null,
                              onRepeat: queueController.cycleRepeatMode,
                            ),
                            Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: timelineWidth,
                                ),
                                child: Row(
                                  children: [
                                    Text(_compactDuration(playback.position)),
                                    Expanded(
                                      child: Slider(
                                        value: positionMs.toDouble(),
                                        max: durationMs > 0
                                            ? durationMs.toDouble()
                                            : 1,
                                        onChanged: hasTrack && durationMs > 0
                                            ? (value) => controller.seek(
                                                Duration(
                                                  milliseconds: value.round(),
                                                ),
                                              )
                                            : null,
                                      ),
                                    ),
                                    Text(_compactDuration(playback.duration)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 248,
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: playback.itemId == null
                                  ? null
                                  : onToggleLyrics,
                              tooltip: lyricsVisible
                                  ? 'Hide lyrics'
                                  : 'Show lyrics',
                              icon: Icon(
                                lyricsVisible
                                    ? Icons.lyrics_rounded
                                    : Icons.lyrics_outlined,
                              ),
                            ),
                            IconButton(
                              tooltip: queueVisible
                                  ? 'Hide queue'
                                  : 'Show queue',
                              onPressed: onToggleQueue,
                              icon: Icon(
                                queueVisible
                                    ? Icons.queue_music_rounded
                                    : Icons.queue_music_outlined,
                              ),
                            ),
                            const Icon(Icons.volume_up_rounded, size: 20),
                            Expanded(
                              child: Slider(
                                value: playback.volume.clamp(0, 1),
                                onChanged: controller.setVolume,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

String _compactDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class _LibraryMessage extends StatelessWidget {
  const _LibraryMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.buttonLabel,
    this.onPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: GazeColors.textSecondary),
            const SizedBox(height: GazeSpacing.small),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: GazeSpacing.small),
            Text(message, textAlign: TextAlign.center),
            if (buttonLabel != null && onPressed != null) ...[
              const SizedBox(height: GazeSpacing.large),
              FilledButton(onPressed: onPressed, child: Text(buttonLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
