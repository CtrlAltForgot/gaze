import 'dart:async';

import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/album_summary.dart';
import 'albums_page.dart';

enum _LibraryDestination { home, albums }

class DesktopShell extends StatefulWidget {
  const DesktopShell({
    required this.connectionController,
    required this.onOpenJellyfinConnection,
    required this.onOpenPlaybackTest,
    super.key,
  });

  final JellyfinConnectionController connectionController;
  final VoidCallback onOpenJellyfinConnection;
  final VoidCallback onOpenPlaybackTest;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  List<AlbumSummary> _albums = const [];
  bool _loading = false;
  String? _error;
  StreamSubscription<JellyfinConnectionState>? _connectionSubscription;
  _LibraryDestination _destination = _LibraryDestination.home;

  bool get _connected => widget.connectionController.state.isConnected;

  @override
  void initState() {
    super.initState();
    _connectionSubscription = widget.connectionController.states.listen(
      _handleConnectionState,
    );
    if (_connected) {
      _loadAlbums();
    }
  }

  void _handleConnectionState(JellyfinConnectionState state) {
    if (!mounted) {
      return;
    }
    if (state.isConnected) {
      _loadAlbums();
    } else {
      setState(() {
        _albums = const [];
        _loading = state.status == JellyfinConnectionStatus.connecting;
        _error = state.errorMessage;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_connectionSubscription?.cancel());
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
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
                      onDestinationChanged: (destination) =>
                          setState(() => _destination = destination),
                      onOpenJellyfinConnection: widget.onOpenJellyfinConnection,
                      onOpenPlaybackTest: widget.onOpenPlaybackTest,
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(
                      child: switch (_destination) {
                        _LibraryDestination.home => _HomeContent(
                          connected: _connected,
                          loading: _loading,
                          albums: _albums,
                          error: _error,
                          onConnect: widget.onOpenJellyfinConnection,
                          onRetry: _loadAlbums,
                        ),
                        _LibraryDestination.albums => AlbumsPage(
                          connectionController: widget.connectionController,
                          onConnect: widget.onOpenJellyfinConnection,
                        ),
                      },
                    ),
                  ],
                ),
              ),
              const _PlayerPlaceholder(),
            ],
          );
        },
      ),
    );
  }
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
      color: GazeColors.navigation,
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
          color: selected ? GazeColors.surfaceRaised : Colors.transparent,
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
    required this.albums,
    required this.error,
    required this.onConnect,
    required this.onRetry,
  });

  final bool connected;
  final bool loading;
  final List<AlbumSummary> albums;
  final String? error;
  final VoidCallback onConnect;
  final VoidCallback onRetry;

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
            child: Row(
              children: [
                Expanded(
                  child: Column(
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
                  ),
                ),
                const SizedBox(width: GazeSpacing.large),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: const TextField(
                    decoration: InputDecoration(
                      hintText: 'Search your library',
                      prefixIcon: Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: GazeColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(GazeRadii.control),
                        ),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (loading)
          const SliverPadding(
            padding: EdgeInsets.symmetric(vertical: GazeSpacing.xxLarge),
            sliver: SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (!connected)
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
        else if (error != null)
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
        else if (albums.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _LibraryMessage(
              icon: Icons.album_outlined,
              title: 'No albums found',
              message:
                  'gaze connected successfully, but Jellyfin returned no music albums.',
            ),
          ),
        if (connected && !loading && error == null && albums.isNotEmpty)
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
        if (connected && !loading && error == null && albums.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              0,
              GazeSpacing.xLarge,
              GazeSpacing.xLarge,
            ),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final columns = width >= 1160
                    ? 5
                    : width >= 880
                    ? 4
                    : width >= 600
                    ? 3
                    : 2;
                return SliverGrid.builder(
                  itemCount: albums.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: GazeSpacing.large,
                    mainAxisSpacing: GazeSpacing.xLarge,
                    childAspectRatio: 0.78,
                  ),
                  itemBuilder: (context, index) =>
                      _AlbumCard(album: albums[index]),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album});

  final AlbumSummary album;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${album.title} by ${album.artist}',
      child: InkWell(
        onTap: () {},
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

class _PlayerPlaceholder extends StatelessWidget {
  const _PlayerPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: GazeSpacing.large),
      decoration: const BoxDecoration(
        color: GazeColors.navigation,
        border: Border(top: BorderSide(color: GazeColors.outline)),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: GazeColors.surfaceRaised,
              borderRadius: BorderRadius.circular(GazeRadii.control),
            ),
            child: const Icon(
              Icons.music_note_rounded,
              color: GazeColors.textSecondary,
            ),
          ),
          const SizedBox(width: GazeSpacing.medium),
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nothing playing',
                  style: TextStyle(
                    color: GazeColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: GazeSpacing.xSmall),
                Text('Choose something when your library is connected.'),
              ],
            ),
          ),
          const _DisabledPlayerControl(
            icon: Icons.skip_previous_rounded,
            label: 'Previous',
          ),
          const _DisabledPlayerControl(
            icon: Icons.play_arrow_rounded,
            label: 'Play',
            prominent: true,
          ),
          const _DisabledPlayerControl(
            icon: Icons.skip_next_rounded,
            label: 'Next',
          ),
        ],
      ),
    );
  }
}

class _DisabledPlayerControl extends StatelessWidget {
  const _DisabledPlayerControl({
    required this.icon,
    required this.label,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: null,
      tooltip: label,
      iconSize: prominent ? 30 : 24,
      icon: Icon(icon),
    );
  }
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
