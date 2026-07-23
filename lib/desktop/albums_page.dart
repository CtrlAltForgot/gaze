import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/album_summary.dart';
import '../library/track_summary.dart';
import 'smooth_scroll_controller.dart';

class AlbumsPage extends StatefulWidget {
  const AlbumsPage({
    required this.connectionController,
    required this.onConnect,
    required this.onPlayTrack,
    this.initialAlbum,
    this.initialAlbumBackLabel = 'All albums',
    this.onInitialAlbumBack,
    super.key,
  });

  final JellyfinConnectionController connectionController;
  final VoidCallback onConnect;
  final AlbumSummary? initialAlbum;
  final String initialAlbumBackLabel;
  final VoidCallback? onInitialAlbumBack;
  final Future<void> Function(
    AlbumSummary album,
    List<TrackSummary> tracks,
    int startIndex,
  )
  onPlayTrack;

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  static const _pageSize = 24;
  static const _loadAheadDistance = 700.0;

  final List<AlbumSummary> _albums = [];
  final SmoothScrollController _scrollController = SmoothScrollController();
  AlbumSort _sort = AlbumSort.title;
  bool _loading = false;
  bool _loadingMore = false;
  int _totalCount = 0;
  bool _showingStaleData = false;
  DateTime? _cachedAt;
  String? _error;
  AlbumSummary? _selectedAlbum;

  bool get _connected => widget.connectionController.state.canBrowseLibrary;
  bool get _hasMore => _albums.length < _totalCount;

  @override
  void initState() {
    super.initState();
    _selectedAlbum = widget.initialAlbum;
    _scrollController.addListener(_loadAhead);
    if (_connected && _selectedAlbum == null) {
      _loadFirstPage();
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_loadAhead)
      ..dispose();
    super.dispose();
  }

  void _loadAhead() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < _loadAheadDistance) {
      _loadMore();
    }
  }

  void _scheduleLoadAhead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasMore || _loading || _loadingMore) {
        return;
      }
      if (!_scrollController.hasClients ||
          _scrollController.position.extentAfter < _loadAheadDistance) {
        _loadMore();
      }
    });
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
      _albums.clear();
      _totalCount = 0;
    });
    try {
      final page = await widget.connectionController.loadAlbums(
        sort: _sort,
        startIndex: 0,
        limit: _pageSize,
      );
      if (mounted) {
        setState(() {
          _albums.addAll(page.albums);
          _totalCount = page.totalCount;
          _showingStaleData = page.isStale;
          _cachedAt = page.cachedAt;
        });
        _scheduleLoadAhead();
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) {
      return;
    }
    setState(() => _loadingMore = true);
    setState(() => _error = null);
    try {
      final page = await widget.connectionController.loadAlbums(
        sort: _sort,
        startIndex: _albums.length,
        limit: _pageSize,
      );
      if (mounted) {
        setState(() {
          _albums.addAll(page.albums);
          _totalCount = page.totalCount;
          _showingStaleData = _showingStaleData || page.isStale;
          _cachedAt ??= page.cachedAt;
        });
        _scheduleLoadAhead();
      }
    } on Exception catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _changeSort(AlbumSort? sort) {
    if (sort == null || sort == _sort) {
      return;
    }
    setState(() => _sort = sort);
    _loadFirstPage();
  }

  Future<void> _retryConnection() async {
    await widget.connectionController.reconnect();
    await _loadFirstPage();
  }

  @override
  Widget build(BuildContext context) {
    _scrollController.smoothingEnabled = !MediaQuery.disableAnimationsOf(
      context,
    );
    final album = _selectedAlbum;
    if (album != null) {
      return _AlbumDetail(
        album: album,
        connectionController: widget.connectionController,
        onPlayTrack: (tracks, index) =>
            widget.onPlayTrack(album, tracks, index),
        backLabel: widget.initialAlbum == album
            ? widget.initialAlbumBackLabel
            : 'All albums',
        onBack:
            widget.initialAlbum == album && widget.onInitialAlbumBack != null
            ? widget.onInitialAlbumBack!
            : () => setState(() => _selectedAlbum = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            GazeSpacing.xLarge,
            GazeSpacing.large,
            GazeSpacing.xLarge,
            GazeSpacing.medium,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Albums',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: GazeSpacing.xSmall),
                    Text(
                      _loading
                          ? 'Loading your library…'
                          : _totalCount == 1
                          ? '1 album'
                          : '$_totalCount albums',
                    ),
                  ],
                ),
              ),
              DropdownButton<AlbumSort>(
                value: _sort,
                onChanged: _loading ? null : _changeSort,
                items: AlbumSort.values
                    .map(
                      (sort) => DropdownMenuItem(
                        value: sort,
                        child: Text(_sortLabel(sort)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          ),
        ),
        if (_showingStaleData)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              0,
              GazeSpacing.xLarge,
              GazeSpacing.medium,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .07),
                border: Border.all(color: Colors.white.withValues(alpha: .14)),
                borderRadius: BorderRadius.circular(GazeRadii.control),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: GazeSpacing.medium,
                  vertical: GazeSpacing.small,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 18),
                    const SizedBox(width: GazeSpacing.small),
                    Expanded(
                      child: Text(
                        _cachedAt == null
                            ? 'Showing saved library data while Jellyfin is unavailable.'
                            : 'Showing saved library data from ${_cachedTime(_cachedAt!)} while Jellyfin is unavailable.',
                      ),
                    ),
                    TextButton(
                      onPressed: _retryConnection,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (!_connected) {
      return _PageMessage(
        icon: Icons.cloud_outlined,
        title: 'Connect your Jellyfin library',
        message: 'Connect before browsing albums.',
        buttonLabel: 'Connect Jellyfin',
        onPressed: widget.onConnect,
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _albums.isEmpty) {
      return _PageMessage(
        icon: Icons.cloud_off_outlined,
        title: 'Albums could not be loaded',
        message: _error!,
        buttonLabel: 'Try again',
        onPressed: _loadFirstPage,
      );
    }
    if (_albums.isEmpty) {
      return const _PageMessage(
        icon: Icons.album_outlined,
        title: 'No albums found',
        message: 'Jellyfin returned no music albums for this account.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                GazeSpacing.xLarge,
                GazeSpacing.small,
                GazeSpacing.xLarge,
                GazeSpacing.large,
              ),
              sliver: SliverGrid.builder(
                itemCount: _albums.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 230,
                  crossAxisSpacing: GazeSpacing.large,
                  mainAxisSpacing: GazeSpacing.xLarge,
                  childAspectRatio: 0.76,
                ),
                itemBuilder: (context, index) => _AlbumTile(
                  album: _albums[index],
                  onTap: () => setState(() => _selectedAlbum = _albums[index]),
                ),
              ),
            ),
            if (_hasMore || _loadingMore || _error != null)
              SliverPadding(
                padding: const EdgeInsets.only(bottom: GazeSpacing.xLarge),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: _error != null
                        ? TextButton.icon(
                            onPressed: _loadMore,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Retry loading albums'),
                          )
                        : const Padding(
                            padding: EdgeInsets.all(GazeSpacing.medium),
                            child: CircularProgressIndicator(),
                          ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

String _cachedTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour == 0
      ? 12
      : local.hour > 12
      ? local.hour - 12
      : local.hour;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '${local.month}/${local.day} at $hour:$minute $period';
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.album, required this.onTap});

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
            Expanded(child: _Artwork(album: album)),
            const SizedBox(height: GazeSpacing.small),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: GazeSpacing.xSmall),
            Text(
              album.year == null
                  ? album.artist
                  : '${album.artist} · ${album.year}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumDetail extends StatefulWidget {
  const _AlbumDetail({
    required this.album,
    required this.connectionController,
    required this.onBack,
    required this.onPlayTrack,
    required this.backLabel,
  });

  final AlbumSummary album;
  final JellyfinConnectionController connectionController;
  final VoidCallback onBack;
  final Future<void> Function(List<TrackSummary> tracks, int index) onPlayTrack;
  final String backLabel;

  @override
  State<_AlbumDetail> createState() => _AlbumDetailState();
}

class _AlbumDetailState extends State<_AlbumDetail> {
  List<TrackSummary>? _tracks;
  String? _error;
  final SmoothScrollController _scrollController = SmoothScrollController();

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadTracks() async {
    setState(() => _error = null);
    try {
      final tracks = await widget.connectionController.loadAlbumTracks(
        widget.album.id,
      );
      if (mounted) {
        setState(() => _tracks = tracks);
      }
    } on Exception catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _scrollController.smoothingEnabled = !MediaQuery.disableAnimationsOf(
      context,
    );
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(GazeSpacing.xLarge),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton.icon(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                  label: Text(widget.backLabel),
                ),
                const SizedBox(height: GazeSpacing.medium),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox.square(
                      dimension: 220,
                      child: _Artwork(album: widget.album),
                    ),
                    const SizedBox(width: GazeSpacing.xLarge),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Album',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: GazeSpacing.small),
                          Text(
                            widget.album.title,
                            style: Theme.of(context).textTheme.headlineLarge,
                          ),
                          const SizedBox(height: GazeSpacing.small),
                          Text(widget.album.artist),
                          if (widget.album.year case final year?) Text('$year'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_tracks == null && _error == null)
          const SliverToBoxAdapter(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error case final error?)
          SliverToBoxAdapter(
            child: _PageMessage(
              icon: Icons.error_outline_rounded,
              title: 'Tracks could not be loaded',
              message: error,
              buttonLabel: 'Try again',
              onPressed: _loadTracks,
            ),
          )
        else if (_tracks!.isEmpty)
          const SliverToBoxAdapter(
            child: _PageMessage(
              icon: Icons.music_off_rounded,
              title: 'No tracks found',
              message: 'Jellyfin returned no tracks for this album.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GazeSpacing.xLarge,
              0,
              GazeSpacing.xLarge,
              GazeSpacing.xLarge,
            ),
            sliver: SliverList.separated(
              itemCount: _tracks!.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final track = _tracks![index];
                return _TrackRow(
                  track: track,
                  displayNumber: track.trackNumber ?? index + 1,
                  onPlay: () => widget.onPlayTrack(_tracks!, index),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _TrackRow extends StatefulWidget {
  const _TrackRow({
    required this.track,
    required this.displayNumber,
    required this.onPlay,
  });

  final TrackSummary track;
  final int displayNumber;
  final VoidCallback onPlay;

  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final showPlay = _hovered || _focused;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        onFocusChange: (value) => setState(() => _focused = value),
        child: ListTile(
          onTap: widget.onPlay,
          leading: SizedBox(
            width: 32,
            child: showPlay
                ? const Icon(Icons.play_arrow_rounded, key: ValueKey('play'))
                : Text('${widget.displayNumber}'),
          ),
          title: Text(widget.track.title),
          subtitle: Text(widget.track.artist),
          trailing: Text(_durationLabel(widget.track.duration)),
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.album});

  final AlbumSummary album;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GazeColors.surfaceRaised,
        borderRadius: BorderRadius.circular(GazeRadii.card),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GazeRadii.card),
        child: album.artworkBytes == null
            ? const Center(
                child: Icon(
                  Icons.album_rounded,
                  size: 48,
                  color: GazeColors.textSecondary,
                ),
              )
            : Image.memory(album.artworkBytes!, fit: BoxFit.cover),
      ),
    );
  }
}

class _PageMessage extends StatelessWidget {
  const _PageMessage({
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
      child: Padding(
        padding: const EdgeInsets.all(GazeSpacing.xLarge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: GazeColors.textSecondary),
            const SizedBox(height: GazeSpacing.medium),
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

String _sortLabel(AlbumSort sort) => switch (sort) {
  AlbumSort.recentlyAdded => 'Recently added',
  AlbumSort.title => 'Album title',
  AlbumSort.artist => 'Artist',
  AlbumSort.releaseYear => 'Release year',
};

String _durationLabel(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
