import 'dart:async';
import 'package:flutter/material.dart';
import '../design/gaze_motion.dart';
import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/artist_credits.dart';
import '../library/artist_profile.dart';
import '../library/song_summary.dart';
import '../library/track_summary.dart';
import 'albums_page.dart';
import 'artist_links.dart';
import 'external_artist_link.dart';
import 'smooth_scroll_controller.dart';
import 'marquee_text.dart';
import 'song_row.dart';
import 'track_selection.dart';

class ArtistsPage extends StatefulWidget {
  const ArtistsPage({
    required this.connectionController,
    required this.onConnect,
    required this.onPlayTrack,
    this.onPlaySongs,
    this.initialArtist,
    this.navigationRevision = 0,
    super.key,
  });
  final JellyfinConnectionController connectionController;
  final VoidCallback onConnect;
  final Future<void> Function(AlbumSummary, List<TrackSummary>, int)
  onPlayTrack;
  final Future<void> Function(List<SongSummary>, int)? onPlaySongs;
  final String? initialArtist;
  final int navigationRevision;
  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  final _scroll = SmoothScrollController();
  final _detailScroll = SmoothScrollController();
  List<ArtistSummary> _artists = [];
  List<SongSummary> _songs = [];
  ArtistSummary? _selectedArtist;
  AlbumSummary? _selectedAlbum;
  ArtistProfile? _profile;
  bool _loading = false,
      _songsLoading = false,
      _profileLoading = false,
      _showAll = false;
  String? _error, _songError, _account;
  int _generation = 0, _detailGeneration = 0;
  StreamSubscription<JellyfinConnectionState>? _connection;
  StreamSubscription<void>? _library;
  bool get _canBrowse => widget.connectionController.state.canBrowseLibrary;

  @override
  void initState() {
    super.initState();
    _account = widget.connectionController.accountKey;
    _connection = widget.connectionController.states.listen((state) {
      if (!mounted) return;
      if (_account != widget.connectionController.accountKey) {
        _generation++;
        _detailGeneration++;
        _account = widget.connectionController.accountKey;
        _artists = [];
        _selectedArtist = null;
        _selectedAlbum = null;
        _songs = [];
        _profile = null;
        _loading = false;
      }
      setState(() {});
      if (state.canBrowseLibrary && !_loading) unawaited(_load());
    });
    _library = widget.connectionController.libraryChanges.listen((_) {
      if (mounted && !_loading) unawaited(_load());
    });
    if (_canBrowse) unawaited(_load());
    if (widget.initialArtist != null)
      unawaited(_openName(widget.initialArtist!));
  }

  @override
  void didUpdateWidget(ArtistsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialArtist != null &&
        (oldWidget.navigationRevision != widget.navigationRevision ||
            oldWidget.initialArtist != widget.initialArtist))
      unawaited(_openName(widget.initialArtist!));
  }

  @override
  void dispose() {
    _generation++;
    _detailGeneration++;
    unawaited(_connection?.cancel());
    unawaited(_library?.cancel());
    _scroll.dispose();
    _detailScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await for (final artists
          in widget.connectionController.watchArtistCatalog()) {
        if (!mounted || generation != _generation) return;
        setState(() => _artists = artists);
      }
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _error = 'Your artist library could not be refreshed.');
    } finally {
      if (mounted && generation == _generation)
        setState(() => _loading = false);
    }
  }

  Future<void> _openName(String name) => _openArtist(
    _artists.where((a) => artistKey(a.name) == artistKey(name)).firstOrNull ??
        ArtistSummary(id: artistId(name), name: name),
  );

  Future<void> _openArtist(ArtistSummary artist) async {
    final generation = ++_detailGeneration;
    setState(() {
      _selectedArtist = artist;
      _selectedAlbum = null;
      _songs = [];
      _profile = null;
      _songsLoading = true;
      _profileLoading = true;
      _songError = null;
      _showAll = false;
    });
    var profileStarted = false;
    void profile() {
      if (profileStarted) return;
      profileStarted = true;
      unawaited(_loadProfile(artist.name, generation));
    }

    try {
      await for (final songs in widget.connectionController.watchArtistSongs(
        artist.name,
      )) {
        if (!mounted || generation != _detailGeneration) return;
        setState(() => _songs = songs);
        if (songs.isNotEmpty) profile();
      }
    } catch (_) {
      if (mounted && generation == _detailGeneration)
        setState(() => _songError = 'Songs could not be refreshed.');
    } finally {
      if (mounted && generation == _detailGeneration) {
        setState(() => _songsLoading = false);
        profile();
      }
    }
  }

  Future<void> _loadProfile(String name, int generation) async {
    try {
      final profile = await widget.connectionController.artistProfileProvider
          ?.find(
            name,
            recordings: _songs.map((s) => s.track.title).take(2).toList(),
          );
      if (mounted && generation == _detailGeneration)
        setState(() => _profile = profile);
    } catch (_) {
      /* Music remains usable when public information is unavailable. */
    } finally {
      if (mounted && generation == _detailGeneration)
        setState(() => _profileLoading = false);
    }
  }

  Future<void> _play(List<SongSummary> songs, int index) async {
    if (widget.onPlaySongs != null) return widget.onPlaySongs!(songs, index);
    final song = songs[index];
    return widget.onPlayTrack(
      AlbumSummary(
        id: song.albumId ?? song.track.id,
        title: song.album,
        artist: song.track.artist,
        imageTag: song.imageTag,
      ),
      [song.track],
      0,
    );
  }

  @override
  Widget build(BuildContext context) {
    _scroll.smoothingEnabled = !MediaQuery.disableAnimationsOf(context);
    _detailScroll.smoothingEnabled = _scroll.smoothingEnabled;
    final artist = _selectedArtist;
    final album = _selectedAlbum;
    return GazeSwap(
      alignment: Alignment.topLeft,
      child: KeyedSubtree(
        key: ValueKey('${artist?.id}:${album?.id}'),
        child: album != null && artist != null
            ? AlbumsPage(
                connectionController: widget.connectionController,
                onConnect: widget.onConnect,
                onPlayTrack: widget.onPlayTrack,
                initialAlbum: album,
                initialAlbumBackLabel: artist.name,
                onInitialAlbumBack: () => setState(() => _selectedAlbum = null),
              )
            : artist != null
            ? _detail(artist)
            : _catalog(),
      ),
    );
  }

  Widget _catalog() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Artists',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _artists.length == 1
                        ? '1 artist'
                        : '${_artists.length} artists',
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Refresh artists',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
      Expanded(
        child: !_canBrowse
            ? _ArtistsMessage(
                icon: Icons.cloud_outlined,
                title: 'Connect your library',
                message: 'Connect to browse your artists.',
                buttonLabel: 'Connect',
                onPressed: widget.onConnect,
              )
            : _artists.isEmpty && _loading
            ? const Center(child: CircularProgressIndicator())
            : _artists.isEmpty
            ? _ArtistsMessage(
                icon: Icons.people_outline,
                title: _error ?? 'No artists yet',
                message: 'Artists appear automatically as music is added.',
                buttonLabel: 'Refresh',
                onPressed: _load,
              )
            : GridView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
                itemCount: _artists.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  crossAxisSpacing: 24,
                  mainAxisSpacing: 32,
                  childAspectRatio: .82,
                ),
                itemBuilder: (context, i) => _ArtistCard(
                  artist: _artists[i],
                  onTap: () => _openArtist(_artists[i]),
                  connectionController: widget.connectionController,
                ),
              ),
      ),
    ],
  );

  Widget _detail(ArtistSummary artist) {
    final profile = _profile;
    final popular = profile == null
        ? <SongSummary>[]
        : popularLibrarySongs(profile, _songs);
    final shown = _showAll
        ? _songs
        : popular.isNotEmpty
        ? popular.take(5).toList()
        : _songs.take(10).toList();
    final albums = <String, AlbumSummary>{};
    for (final song in _songs) {
      if (song.albumId != null)
        albums.putIfAbsent(
          song.albumId!,
          () => AlbumSummary(
            id: song.albumId!,
            title: song.album,
            artist: song.track.artist,
            imageTag: song.imageTag,
            artworkBytes: song.artworkBytes,
          ),
        );
    }
    final age = profile?.ageAt(DateTime.now());
    final facts = <String>[
      if (profile?.origin != null) profile!.origin!,
      if (age != null) '$age years old',
      if (profile?.type == 'Group' && profile?.born != null)
        'Formed ${profile!.born!.split('-').first}',
    ];
    return TrackSelectionScope(
      child: CustomScrollView(
        controller: _detailScroll,
        key: PageStorageKey('artist:${artist.id}'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _detailGeneration++;
                      _selectedArtist = null;
                      _selectedAlbum = null;
                    }),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('All artists'),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox.square(
                        dimension: 180,
                        child: GazeSwap(
                          child: profile?.photoUrl == null
                              ? _ArtistArtwork(
                                  artist: artist,
                                  connectionController:
                                      widget.connectionController,
                                )
                              : ClipRRect(
                                  key: ValueKey(profile!.photoUrl),
                                  borderRadius: BorderRadius.circular(20),
                                  child: Image.network(
                                    profile.photoUrl!,
                                    fit: BoxFit.cover,
                                    cacheWidth: 500,
                                    errorBuilder: (_, _, _) => _ArtistArtwork(
                                      artist: artist,
                                      connectionController:
                                          widget.connectionController,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 28),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ARTIST',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(letterSpacing: 2),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              artist.name,
                              style: Theme.of(
                                context,
                              ).textTheme.headlineLarge?.copyWith(fontSize: 42),
                            ),
                            const SizedBox(height: 12),
                            if (facts.isNotEmpty) Text(facts.join(' · ')),
                            const SizedBox(height: 8),
                            Text('${_songs.length} songs in your library'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (profile?.biography?.isNotEmpty == true) ...[
                    const SizedBox(height: 28),
                    Text(
                      'About',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 850),
                      child: Text(
                        profile!.biography!,
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.55),
                      ),
                    ),
                  ],
                  if (profile != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 12,
                        children: [
                          if (profile.wikipediaUrl != null)
                            ExternalArtistLink(
                              label: 'Biography · Wikipedia (CC BY-SA)',
                              url: profile.wikipediaUrl!,
                            ),
                          ExternalArtistLink(
                            label: 'Artist details · MusicBrainz',
                            url:
                                'https://musicbrainz.org/artist/${profile.musicBrainzId}',
                          ),
                          if (profile.photoSource != null)
                            ExternalArtistLink(
                              label: 'Photo credit',
                              url: profile.photoSource!,
                              credit: profile.photoCredit,
                            ),
                        ],
                      ),
                    ),
                  if (_profileLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Loading artist details…',
                        style: TextStyle(color: GazeColors.textSecondary),
                      ),
                    ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          !_showAll && popular.isNotEmpty
                              ? 'Popular in your library'
                              : 'Songs in your library',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      if (_songs.length > shown.length || _showAll)
                        TextButton(
                          onPressed: () => setState(() => _showAll = !_showAll),
                          child: Text(
                            _showAll ? 'Show highlights' : 'Show all songs',
                          ),
                        ),
                    ],
                  ),
                  if (!_showAll && popular.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: ExternalArtistLink(
                        label: 'Ranked by ListenBrainz listens',
                        url: 'https://listenbrainz.org',
                      ),
                    ),
                  if (_songError != null)
                    TextButton(
                      onPressed: () => _openArtist(artist),
                      child: Text('$_songError Retry'),
                    ),
                ],
              ),
            ),
          ),
          if (_songsLoading && shown.isEmpty)
            const SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
          if (!_songsLoading && shown.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No playable songs for this artist yet.'),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            sliver: SliverList.builder(
              itemCount: shown.length,
              itemBuilder: (context, i) => SongRow(
                song: shown[i],
                connectionController: widget.connectionController,
                showAlbum: true,
                displayNumber: i + 1,
                onPlay: widget.connectionController.state.isConnected
                    ? (_) => _play(shown, i)
                    : null,
              ),
            ),
          ),
          if (albums.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 20),
                child: Text(
                  'Albums & appearances',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              sliver: SliverGrid.builder(
                itemCount: albums.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  crossAxisSpacing: 24,
                  mainAxisSpacing: 32,
                  childAspectRatio: .78,
                ),
                itemBuilder: (context, i) {
                  final album = albums.values.elementAt(i);
                  return _ArtistAlbumCard(
                    album: album,
                    connectionController: widget.connectionController,
                    onTap: () => setState(() => _selectedAlbum = album),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({
    required this.artist,
    required this.onTap,
    required this.connectionController,
  });

  final JellyfinConnectionController connectionController;

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
            Expanded(
              child: _ArtistArtwork(
                artist: artist,
                connectionController: connectionController,
              ),
            ),
            const SizedBox(height: GazeSpacing.medium),
            MarqueeText(
              artist.name,
              hoverOnly: true,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistArtwork extends StatelessWidget {
  const _ArtistArtwork({
    required this.artist,
    required this.connectionController,
  });

  final JellyfinConnectionController connectionController;

  final ArtistSummary artist;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipOval(
        child: ColoredBox(
          color: GazeColors.surfaceRaised,
          child: LibraryArtwork(
            connectionController: connectionController,
            itemId: artist.artworkId,
            imageTag: artist.imageTag,
            bytes: artist.artworkBytes,
            dimension: double.infinity,
            icon: Icons.person_rounded,
            iconSize: 64,
          ),
        ),
      ),
    );
  }
}

class _ArtistAlbumCard extends StatelessWidget {
  const _ArtistAlbumCard({
    required this.album,
    required this.onTap,
    required this.connectionController,
  });

  final JellyfinConnectionController connectionController;

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
                  child: LibraryArtwork(
                    connectionController: connectionController,
                    itemId: album.id,
                    imageTag: album.imageTag,
                    bytes: album.artworkBytes,
                    dimension: double.infinity,
                    icon: Icons.album_rounded,
                    iconSize: 52,
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
          ArtistLinks(album.artist, hoverOnly: true),
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
