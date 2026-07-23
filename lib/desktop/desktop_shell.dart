import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import '../design/artwork_palette.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/album_summary.dart';
import '../library/library_search_results.dart';
import '../library/track_lyrics.dart';
import '../library/track_summary.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_queue_controller.dart';
import '../storage/artwork_palette_cache.dart';
import 'albums_page.dart';

enum _LibraryDestination { home, albums }

class DesktopShell extends StatefulWidget {
  const DesktopShell({
    required this.connectionController,
    required this.playbackController,
    required this.queueController,
    required this.onOpenJellyfinConnection,
    required this.onOpenPlaybackTest,
    this.paletteCache = const DisabledArtworkPaletteCache(),
    super.key,
  });

  final JellyfinConnectionController connectionController;
  final PlaybackController playbackController;
  final PlaybackQueueController queueController;
  final VoidCallback onOpenJellyfinConnection;
  final VoidCallback onOpenPlaybackTest;
  final ArtworkPaletteCache paletteCache;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  List<AlbumSummary> _albums = const [];
  bool _loading = false;
  bool _offline = false;
  String? _error;
  StreamSubscription<JellyfinConnectionState>? _connectionSubscription;
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  _LibraryDestination _destination = _LibraryDestination.home;
  AlbumSummary? _albumOpenedFromHome;
  ArtworkPalette _palette = ArtworkPalette.fallback;
  Uint8List? _paletteArtwork;
  Timer? _searchDebounce;
  String _searchQuery = '';
  LibrarySearchResults? _searchResults;
  bool _searching = false;
  String? _searchError;
  int _searchRequest = 0;
  bool _lyricsVisible = false;

  bool get _connected => widget.connectionController.state.canBrowseLibrary;

  @override
  void initState() {
    super.initState();
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
  }

  void _handleConnectionState(JellyfinConnectionState state) {
    if (!mounted) {
      return;
    }
    if (state.canBrowseLibrary) {
      setState(
        () => _offline = state.status == JellyfinConnectionStatus.offline,
      );
      _loadAlbums();
    } else {
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
    unawaited(_connectionSubscription?.cancel());
    unawaited(_playbackSubscription?.cancel());
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _handlePlaybackState(PlaybackSnapshot playback) async {
    final artwork = playback.artworkBytes;
    if (artwork == null || identical(artwork, _paletteArtwork)) {
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

  Future<void> _loadAlbums() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final albums = await widget.connectionController.loadRecentlyAddedAlbums(
        limit: 10,
      );
      if (mounted) {
        setState(() => _albums = albums);
      }
    } on Exception catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _retryConnection() async {
    await widget.connectionController.reconnect();
    await _loadAlbums();
  }

  void _openAlbum(AlbumSummary album) {
    setState(() => _albumOpenedFromHome = album);
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
        artworkBytes: result.artworkBytes,
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
            artworkBytes: album.artworkBytes,
          );
        })
        .toList(growable: false);
    return widget.queueController.playAlbum(sources, startIndex: startIndex);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(primary: _palette.accent),
        sliderTheme: theme.sliderTheme.copyWith(
          activeTrackColor: _palette.accent,
          thumbColor: _palette.accent,
        ),
        focusColor: _palette.accent.withValues(alpha: .24),
      ),
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
                    _palette.background.map((color) => color.toARGB32()).join(),
                  ),
                  colors: _palette.background,
                  weights: _palette.backgroundWeights,
                  animate:
                      _paletteArtwork != null &&
                      !MediaQuery.disableAnimationsOf(context),
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final compactNavigation = constraints.maxWidth < 920;
                return Column(
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Navigation(
                            compact: compactNavigation,
                            destination: _destination,
                            onDestinationChanged: (destination) => setState(() {
                              _albumOpenedFromHome = null;
                              _destination = destination;
                            }),
                            onOpenJellyfinConnection:
                                widget.onOpenJellyfinConnection,
                            onOpenPlaybackTest: widget.onOpenPlaybackTest,
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: Colors.white.withValues(alpha: .16),
                          ),
                          Expanded(
                            child: _albumOpenedFromHome != null
                                ? AlbumsPage(
                                    key: ValueKey(_albumOpenedFromHome!.id),
                                    connectionController:
                                        widget.connectionController,
                                    onConnect: widget.onOpenJellyfinConnection,
                                    onPlayTrack: _playAlbum,
                                    initialAlbum: _albumOpenedFromHome,
                                    initialAlbumBackLabel: 'Home',
                                    onInitialAlbumBack: () => setState(
                                      () => _albumOpenedFromHome = null,
                                    ),
                                  )
                                : switch (_destination) {
                                    _LibraryDestination.home => _HomeContent(
                                      connected: _connected,
                                      loading: _loading,
                                      offline: _offline,
                                      albums: _albums,
                                      error: _error,
                                      onConnect:
                                          widget.onOpenJellyfinConnection,
                                      onRetry: _retryConnection,
                                      onOpenAlbum: _openAlbum,
                                      searchQuery: _searchQuery,
                                      searchResults: _searchResults,
                                      searching: _searching,
                                      searchError: _searchError,
                                      onSearchChanged: _handleSearchChanged,
                                      onPlaySearchTrack: _playSearchTrack,
                                    ),
                                    _LibraryDestination.albums => AlbumsPage(
                                      connectionController:
                                          widget.connectionController,
                                      onConnect:
                                          widget.onOpenJellyfinConnection,
                                      onPlayTrack: _playAlbum,
                                    ),
                                  },
                          ),
                          if (_lyricsVisible) ...[
                            VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: Colors.white.withValues(alpha: .16),
                            ),
                            SizedBox(
                              width: constraints.maxWidth >= 1700
                                  ? 430
                                  : constraints.maxWidth >= 1250
                                  ? 360
                                  : 320,
                              child: _LyricsPanel(
                                connectionController:
                                    widget.connectionController,
                                playbackController: widget.playbackController,
                                onClose: () =>
                                    setState(() => _lyricsVisible = false),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _PlayerBar(
                      controller: widget.playbackController,
                      queueController: widget.queueController,
                      lyricsVisible: _lyricsVisible,
                      onToggleLyrics: () =>
                          setState(() => _lyricsVisible = !_lyricsVisible),
                    ),
                  ],
                );
              },
            ),
          ],
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 36),
  );

  @override
  void initState() {
    super.initState();
    _updateMotion();
  }

  @override
  void didUpdateWidget(_AmbientArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) {
      _updateMotion();
    }
  }

  void _updateMotion() {
    if (widget.animate) {
      _controller.repeat();
    } else {
      _controller
        ..stop()
        ..value = .18;
    }
  }

  @override
  void dispose() {
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
  final Animation<double> motion;

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
    required this.destination,
    required this.onDestinationChanged,
    required this.onOpenJellyfinConnection,
    required this.onOpenPlaybackTest,
  });

  final bool compact;
  final _LibraryDestination destination;
  final ValueChanged<_LibraryDestination> onDestinationChanged;
  final VoidCallback onOpenJellyfinConnection;
  final VoidCallback onOpenPlaybackTest;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: GazeColors.navigation.withValues(alpha: .46),
      child: SizedBox(
        width: compact ? 80 : 224,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? GazeSpacing.small : GazeSpacing.medium,
            vertical: GazeSpacing.large,
          ),
          child: Column(
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: GazeSpacing.small,
                ),
                child: Text(
                  compact ? 'g' : 'gaze',
                  textAlign: compact ? TextAlign.center : TextAlign.left,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: GazeSpacing.xLarge),
              _NavigationItem(
                icon: Icons.home_rounded,
                label: 'Home',
                compact: compact,
                selected: destination == _LibraryDestination.home,
                onTap: () => onDestinationChanged(_LibraryDestination.home),
              ),
              _NavigationItem(
                icon: Icons.album_outlined,
                label: 'Albums',
                compact: compact,
                selected: destination == _LibraryDestination.albums,
                onTap: () => onDestinationChanged(_LibraryDestination.albums),
              ),
              _NavigationItem(
                icon: Icons.people_outline_rounded,
                label: 'Artists',
                compact: compact,
              ),
              _NavigationItem(
                icon: Icons.music_note_rounded,
                label: 'Songs',
                compact: compact,
              ),
              _NavigationItem(
                icon: Icons.queue_music_rounded,
                label: 'Playlists',
                compact: compact,
              ),
              const Spacer(),
              Tooltip(
                message: 'Connect to Jellyfin',
                child: TextButton.icon(
                  onPressed: onOpenJellyfinConnection,
                  icon: const Icon(Icons.cloud_outlined),
                  label: compact
                      ? const SizedBox.shrink()
                      : const Text('Connect Jellyfin'),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: GazeColors.textSecondary,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ),
              Tooltip(
                message: 'Open the playback technical test',
                child: TextButton.icon(
                  onPressed: onOpenPlaybackTest,
                  icon: const Icon(Icons.science_outlined),
                  label: compact
                      ? const SizedBox.shrink()
                      : const Text('Playback test'),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
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
  });

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

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
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
                return ListTile(
                  minTileHeight: 64,
                  leading: _SearchTrackArtwork(result: result),
                  title: Text(result.track.title),
                  subtitle: Text(result.track.artist),
                  trailing: Text(_compactDuration(result.track.duration)),
                  onTap: () => onPlaySearchTrack(result),
                );
              },
            ),
          ),
        if (searchQuery.isEmpty && loading)
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
              buttonLabel: 'Connect Jellyfin',
              onPressed: onConnect,
            ),
          )
        else if (searchQuery.isEmpty && error != null)
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
        if (searchQuery.isEmpty &&
            connected &&
            !loading &&
            error == null &&
            albums.isNotEmpty)
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
        if (searchQuery.isEmpty &&
            connected &&
            !loading &&
            error == null &&
            albums.isNotEmpty)
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

class _SearchTrackArtwork extends StatelessWidget {
  const _SearchTrackArtwork({required this.result});

  final TrackSearchResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: GazeColors.surfaceRaised,
        borderRadius: BorderRadius.circular(GazeRadii.control),
      ),
      child: result.artworkBytes == null
          ? const Icon(
              Icons.music_note_rounded,
              color: GazeColors.textSecondary,
            )
          : Image.memory(result.artworkBytes!, fit: BoxFit.cover),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap});

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
                    child: album.artworkBytes == null
                        ? const Center(
                            child: Icon(
                              Icons.album_rounded,
                              color: GazeColors.textSecondary,
                              size: 52,
                            ),
                          )
                        : Image.memory(
                            album.artworkBytes!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: GazeSpacing.medium),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: GazeSpacing.xSmall),
            Text(album.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _LyricsPanel extends StatefulWidget {
  const _LyricsPanel({
    required this.connectionController,
    required this.playbackController,
    required this.onClose,
  });

  final JellyfinConnectionController connectionController;
  final PlaybackController playbackController;
  final VoidCallback onClose;

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<PlaybackSnapshot>? _subscription;
  PlaybackSnapshot _playback = const PlaybackSnapshot();
  Future<TrackLyrics?>? _lyrics;
  String? _itemId;
  int _activeLine = -1;

  @override
  void initState() {
    super.initState();
    _playback = widget.playbackController.state;
    _loadFor(_playback.itemId);
    _subscription = widget.playbackController.states.listen(_handlePlayback);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  void _loadFor(String? itemId) {
    _itemId = itemId;
    _activeLine = -1;
    _lyrics = itemId == null
        ? null
        : widget.connectionController.loadLyrics(itemId);
  }

  void _handlePlayback(PlaybackSnapshot playback) {
    if (!mounted) {
      return;
    }
    if (playback.itemId != _itemId) {
      setState(() {
        _playback = playback;
        _loadFor(playback.itemId);
      });
      return;
    }
    if (_playback.position != playback.position ||
        _playback.title != playback.title ||
        _playback.artist != playback.artist) {
      setState(() => _playback = playback);
    }
  }

  int _lineAt(TrackLyrics lyrics) {
    if (!lyrics.isSynchronized) {
      return -1;
    }
    var active = -1;
    for (var index = 0; index < lyrics.lines.length; index++) {
      final start = lyrics.lines[index].start;
      if (start == null || start > _playback.position) {
        break;
      }
      active = index;
    }
    if (active != _activeLine) {
      _activeLine = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients || active < 0) {
          return;
        }
        final target = (active * 64.0 - 120).clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );
        if (MediaQuery.disableAnimationsOf(context)) {
          _scrollController.jumpTo(target);
        } else {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
    return active;
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: GazeColors.navigation.withValues(alpha: .44),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.large,
              GazeSpacing.large,
              GazeSpacing.small,
              GazeSpacing.medium,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Lyrics',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: GazeSpacing.xSmall),
                      Text(
                        _playback.title ?? 'Nothing playing',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: widget.onClose,
                  tooltip: 'Close lyrics',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: .14)),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final future = _lyrics;
    if (_itemId == null || future == null) {
      return const _LyricsMessage(
        icon: Icons.lyrics_outlined,
        title: 'Choose a song',
        message: 'Lyrics will appear here while a Jellyfin track is playing.',
      );
    }
    return FutureBuilder<TrackLyrics?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _LyricsMessage(
            icon: Icons.error_outline_rounded,
            title: 'Lyrics could not be loaded',
            message: snapshot.error.toString(),
          );
        }
        final lyrics = snapshot.data;
        if (lyrics == null || lyrics.lines.isEmpty) {
          return const _LyricsMessage(
            icon: Icons.lyrics_outlined,
            title: 'No lyrics available',
            message: 'Jellyfin does not have lyrics saved for this song yet.',
          );
        }
        final active = _lineAt(lyrics);
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(
            horizontal: GazeSpacing.large,
            vertical: GazeSpacing.xLarge,
          ),
          itemExtent: 64,
          itemCount: lyrics.lines.length,
          itemBuilder: (context, index) {
            final line = lyrics.lines[index];
            final selected = index == active;
            return Semantics(
              selected: selected,
              button: line.start != null,
              label: line.text,
              child: InkWell(
                onTap: line.start == null
                    ? null
                    : () => widget.playbackController.seek(line.start!),
                borderRadius: BorderRadius.circular(GazeRadii.control),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedDefaultTextStyle(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    style: Theme.of(context).textTheme.titleMedium!.copyWith(
                      color: selected
                          ? GazeColors.textPrimary
                          : GazeColors.textSecondary,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                    child: Text(
                      line.text.isEmpty ? '♪' : line.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _LyricsMessage extends StatelessWidget {
  const _LyricsMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(GazeSpacing.xLarge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: GazeColors.textSecondary),
            const SizedBox(height: GazeSpacing.medium),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: GazeSpacing.small),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.controller,
    required this.queueController,
    required this.lyricsVisible,
    required this.onToggleLyrics,
  });

  final PlaybackController controller;
  final PlaybackQueueController queueController;
  final bool lyricsVisible;
  final VoidCallback onToggleLyrics;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackSnapshot>(
      stream: controller.states,
      initialData: controller.state,
      builder: (context, snapshot) {
        final playback = snapshot.data ?? controller.state;
        final queue = queueController.state;
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
            final artworkSize = compact ? 60.0 : 76.0;
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
              height: 104,
              padding: EdgeInsets.symmetric(
                horizontal: compact ? GazeSpacing.small : GazeSpacing.large,
              ),
              decoration: BoxDecoration(
                color: GazeColors.navigation.withValues(alpha: .52),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: .16)),
                ),
              ),
              child: Row(
                children: [
                  _PlayerArtwork(playback: playback, dimension: artworkSize),
                  SizedBox(
                    width: compact ? GazeSpacing.small : GazeSpacing.medium,
                  ),
                  SizedBox(
                    width: metadataWidth,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playback.title ?? 'Nothing playing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GazeColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: GazeSpacing.xSmall),
                        Text(
                          playback.errorMessage != null
                              ? playback.errorMessage!
                              : playback.artist?.isNotEmpty == true
                              ? playback.artist!
                              : 'Choose a track from an album.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed:
                                  queue.hasPrevious ||
                                      (hasTrack &&
                                          playback.position >
                                              PlaybackQueueController
                                                  .previousRestartThreshold)
                                  ? queueController.previous
                                  : null,
                              tooltip: 'Previous',
                              iconSize: 30,
                              icon: const Icon(Icons.skip_previous_rounded),
                            ),
                            IconButton.filled(
                              onPressed: hasTrack
                                  ? playing
                                        ? controller.pause
                                        : controller.play
                                  : null,
                              tooltip: playing ? 'Pause' : 'Play',
                              icon: Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                            IconButton(
                              onPressed: queue.hasNext
                                  ? queueController.next
                                  : null,
                              tooltip: 'Next',
                              iconSize: 30,
                              icon: const Icon(Icons.skip_next_rounded),
                            ),
                          ],
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
                    width: compact
                        ? 52
                        : wide
                        ? 200
                        : 160,
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
                        if (!compact) ...[
                          const Icon(Icons.volume_up_rounded, size: 20),
                          Expanded(
                            child: Slider(
                              value: playback.volume.clamp(0, 1),
                              onChanged: controller.setVolume,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _PlayerArtwork extends StatelessWidget {
  const _PlayerArtwork({required this.playback, required this.dimension});

  final PlaybackSnapshot playback;
  final double dimension;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: dimension,
      height: dimension,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: GazeColors.surfaceRaised,
        borderRadius: BorderRadius.circular(GazeRadii.control),
      ),
      child: playback.artworkBytes == null
          ? const Icon(
              Icons.music_note_rounded,
              color: GazeColors.textSecondary,
            )
          : Image.memory(playback.artworkBytes!, fit: BoxFit.cover),
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
