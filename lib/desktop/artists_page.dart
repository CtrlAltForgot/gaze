import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/track_summary.dart';
import 'albums_page.dart';
import 'smooth_scroll_controller.dart';

class ArtistsPage extends StatefulWidget {
  const ArtistsPage({
    required this.connectionController,
    required this.onConnect,
    required this.onPlayTrack,
    super.key,
  });

  final JellyfinConnectionController connectionController;
  final VoidCallback onConnect;
  final Future<void> Function(
    AlbumSummary album,
    List<TrackSummary> tracks,
    int startIndex,
  )
  onPlayTrack;

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  static const _pageSize = 48;
  static const _loadAheadDistance = 700.0;

  final SmoothScrollController _scrollController = SmoothScrollController();
  final List<ArtistSummary> _artists = [];
  int _totalCount = 0;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  ArtistSummary? _selectedArtist;
  AlbumSummary? _selectedAlbum;
  List<AlbumSummary>? _artistAlbums;
  String? _artistError;

  bool get _connected => widget.connectionController.state.isConnected;
  bool get _hasMore => _artists.length < _totalCount;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadAhead);
    if (_connected) {
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

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
      _artists.clear();
      _totalCount = 0;
    });
    try {
      final page = await widget.connectionController.loadArtists(
        startIndex: 0,
        limit: _pageSize,
      );
      if (mounted) {
        setState(() {
          _artists.addAll(page.artists);
          _totalCount = page.totalCount;
        });
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
    try {
      final page = await widget.connectionController.loadArtists(
        startIndex: _artists.length,
        limit: _pageSize,
      );
      if (mounted) {
        setState(() {
          _artists.addAll(page.artists);
          _totalCount = page.totalCount;
        });
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

  Future<void> _openArtist(ArtistSummary artist) async {
    setState(() {
      _selectedArtist = artist;
      _artistAlbums = null;
      _artistError = null;
    });
    try {
      final albums = await widget.connectionController.loadArtistAlbums(
        artist.id,
      );
      if (mounted && _selectedArtist == artist) {
        setState(() => _artistAlbums = albums);
      }
    } on Exception catch (error) {
      if (mounted && _selectedArtist == artist) {
        setState(() => _artistError = error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _scrollController.smoothingEnabled = !MediaQuery.disableAnimationsOf(
      context,
    );
    final artist = _selectedArtist;
    final album = _selectedAlbum;
    if (artist != null && album != null) {
      return AlbumsPage(
        connectionController: widget.connectionController,
        onConnect: widget.onConnect,
        onPlayTrack: widget.onPlayTrack,
        initialAlbum: album,
        initialAlbumBackLabel: artist.name,
        onInitialAlbumBack: () => setState(() => _selectedAlbum = null),
      );
    }
    if (artist != null) {
      return _buildArtist(context, artist);
    }
    return _buildArtists(context);
  }

  Widget _buildArtists(BuildContext context) {
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Artists', style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: GazeSpacing.xSmall),
              Text(
                _loading
                    ? 'Loading your library…'
                    : _totalCount == 1
                    ? '1 artist'
                    : '$_totalCount artists',
              ),
            ],
          ),
        ),
        Expanded(child: _buildArtistsBody()),
      ],
    );
  }

  Widget _buildArtistsBody() {
    if (!_connected) {
      return _ArtistsMessage(
        icon: Icons.cloud_outlined,
        title: 'Connect your Jellyfin library',
        message: 'Connect before browsing artists.',
        buttonLabel: 'Connect Jellyfin',
        onPressed: widget.onConnect,
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _artists.isEmpty) {
      return _ArtistsMessage(
        icon: Icons.cloud_off_outlined,
        title: 'Artists could not be loaded',
        message: _error!,
        buttonLabel: 'Try again',
        onPressed: _loadFirstPage,
      );
    }
    if (_artists.isEmpty) {
      return const _ArtistsMessage(
        icon: Icons.people_outline_rounded,
        title: 'No artists found',
        message: 'Jellyfin returned no music artists for this account.',
      );
    }
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GazeSpacing.xLarge,
            GazeSpacing.small,
            GazeSpacing.xLarge,
            GazeSpacing.xLarge,
          ),
          sliver: SliverGrid.builder(
            itemCount: _artists.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              crossAxisSpacing: GazeSpacing.large,
              mainAxisSpacing: GazeSpacing.xLarge,
              childAspectRatio: .82,
            ),
            itemBuilder: (context, index) {
              final artist = _artists[index];
              return _ArtistCard(
                artist: artist,
                onTap: () => _openArtist(artist),
              );
            },
          ),
        ),
        if (_hasMore || _loadingMore)
          const SliverPadding(
            padding: EdgeInsets.only(bottom: GazeSpacing.xLarge),
            sliver: SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Widget _buildArtist(BuildContext context, ArtistSummary artist) {
    final albums = _artistAlbums;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(GazeSpacing.xLarge),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton.icon(
                  onPressed: () => setState(() {
                    _selectedArtist = null;
                    _artistAlbums = null;
                    _artistError = null;
                  }),
                  icon: const Icon(Icons.arrow_back_rounded),
                  label: const Text('All artists'),
                ),
                const SizedBox(height: GazeSpacing.medium),
                Row(
                  children: [
                    SizedBox.square(
                      dimension: 180,
                      child: _ArtistArtwork(artist: artist),
                    ),
                    const SizedBox(width: GazeSpacing.xLarge),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Artist'),
                          const SizedBox(height: GazeSpacing.small),
                          Text(
                            artist.name,
                            style: Theme.of(context).textTheme.headlineLarge,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: GazeSpacing.xLarge),
                Text(
                  'Albums',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
          ),
        ),
        if (albums == null && _artistError == null)
          const SliverToBoxAdapter(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_artistError != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _ArtistsMessage(
              icon: Icons.error_outline_rounded,
              title: 'Albums could not be loaded',
              message: _artistError!,
              buttonLabel: 'Try again',
              onPressed: () => _openArtist(artist),
            ),
          )
        else if (albums!.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _ArtistsMessage(
              icon: Icons.album_outlined,
              title: 'No albums found',
              message: 'Jellyfin returned no albums for this artist.',
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
            sliver: SliverGrid.builder(
              itemCount: albums.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                crossAxisSpacing: GazeSpacing.large,
                mainAxisSpacing: GazeSpacing.xLarge,
                childAspectRatio: .78,
              ),
              itemBuilder: (context, index) {
                final album = albums[index];
                return _ArtistAlbumCard(
                  album: album,
                  onTap: () => setState(() => _selectedAlbum = album),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.artist, required this.onTap});

  final ArtistSummary artist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: artist.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(GazeRadii.card),
        child: Column(
          children: [
            Expanded(child: _ArtistArtwork(artist: artist)),
            const SizedBox(height: GazeSpacing.medium),
            Text(
              artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistArtwork extends StatelessWidget {
  const _ArtistArtwork({required this.artist});

  final ArtistSummary artist;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipOval(
        child: ColoredBox(
          color: GazeColors.surfaceRaised,
          child: artist.artworkBytes == null
              ? const Icon(
                  Icons.person_rounded,
                  size: 64,
                  color: GazeColors.textSecondary,
                )
              : Image.memory(artist.artworkBytes!, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _ArtistAlbumCard extends StatelessWidget {
  const _ArtistAlbumCard({required this.album, required this.onTap});

  final AlbumSummary album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(GazeRadii.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(GazeRadii.card),
              child: ColoredBox(
                color: GazeColors.surfaceRaised,
                child: SizedBox.expand(
                  child: album.artworkBytes == null
                      ? const Icon(
                          Icons.album_rounded,
                          size: 52,
                          color: GazeColors.textSecondary,
                        )
                      : Image.memory(album.artworkBytes!, fit: BoxFit.cover),
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
          Text(album.year?.toString() ?? album.artist),
        ],
      ),
    );
  }
}

class _ArtistsMessage extends StatelessWidget {
  const _ArtistsMessage({
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
