import '../design/gaze_motion.dart';
import 'marquee_text.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/playlist_summary.dart';
import '../library/song_summary.dart';
import 'smooth_scroll_controller.dart';
import 'track_selection.dart';
import 'song_row.dart';
import 'playlist_dialogs.dart';
import 'playlist_details_dialog.dart';

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({
    required this.connectionController,
    required this.onConnect,
    required this.onPlaySongs,
    required this.onQueueSongs,
    this.onPlayPlaylist,
    this.initialPlaylist,
    this.onPlaylistsChanged,
    this.onSelectionChanged,
    this.navigationRevision = 0,
    super.key,
  });
  final JellyfinConnectionController connectionController;
  final VoidCallback onConnect;
  final Future<void> Function(List<SongSummary>, int) onPlaySongs;
  final Future<void> Function(List<SongSummary>, bool next) onQueueSongs;
  final Future<void> Function(List<SongSummary>)? onPlayPlaylist;
  final PlaylistSummary? initialPlaylist;
  final VoidCallback? onPlaylistsChanged;
  final ValueChanged<PlaylistSummary?>? onSelectionChanged;
  final int navigationRevision;
  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  final SmoothScrollController _collectionScroll = SmoothScrollController();
  final SmoothScrollController _detailScroll = SmoothScrollController();
  SmoothScrollController get _scroll =>
      _selected == null ? _collectionScroll : _detailScroll;
  final TextEditingController _search = TextEditingController();
  List<String> _searchTerms = const [];
  StreamSubscription<JellyfinConnectionState>? _connection;
  List<PlaylistSummary> _playlists = [];
  List<SongSummary> _songs = [];
  PlaylistSummary? _selected;
  int _offset = 0;
  int _total = 0;
  int _request = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _tracksLoading = false;
  bool _tracksReady = false;
  bool _busy = false;
  bool _dialogOpen = false;
  bool _canEdit = false;
  bool _detailsReady = false;
  bool _selectionNotificationPending = false;
  int _trackTotal = 0;
  String? _error;
  bool get _online => widget.connectionController.state.isConnected;
  @override
  void initState() {
    super.initState();
    _collectionScroll.addListener(_loadAhead);
    _connection = widget.connectionController.states.listen((_) {
      if (!mounted) return;
      _request++;
      setState(() {
        _selected = null;
        _songs = [];
        _tracksReady = false;
        _resetSearch();
        _playlists = [];
        _offset = 0;
        _total = 0;
        _loading = false;
        _loadingMore = false;
        _tracksLoading = false;
        _detailsReady = false;
        _error = null;
      });
      _notifySelection();
      if (_online) unawaited(_load());
    });
    if (_online) {
      final initial = widget.initialPlaylist;
      unawaited(initial == null ? _load() : _open(initial));
    }
  }

  @override
  void didUpdateWidget(PlaylistsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.initialPlaylist;
    final next = widget.initialPlaylist;
    if (oldWidget.navigationRevision != widget.navigationRevision ||
        previous?.id != next?.id ||
        previous?.imageTag != next?.imageTag ||
        previous?.title != next?.title ||
        previous?.description != next?.description) {
      if (next == null) {
        _back();
      } else if (_online) {
        unawaited(_open(next));
      }
    }
  }

  @override
  void dispose() {
    _request++;
    unawaited(_connection?.cancel());
    _collectionScroll.dispose();
    _detailScroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _resetSearch() {
    _search.clear();
    _searchTerms = const [];
  }

  void _clearSearch() => setState(_resetSearch);

  List<int> get _matchingSongIndices => [
    for (var index = 0; index < _songs.length; index++)
      if (_matchesSearch(_songs[index])) index,
  ];

  bool _matchesSearch(SongSummary song) {
    if (_searchTerms.isEmpty) return true;
    final metadata = '${song.track.title} ${song.track.artist} ${song.album}'
        .toLowerCase();
    return _searchTerms.every(metadata.contains);
  }

  void _loadAhead() {
    if (_selected == null &&
        _scroll.hasClients &&
        _scroll.position.extentAfter < 700 &&
        !_loading &&
        !_loadingMore &&
        _error == null &&
        _offset < _total)
      unawaited(_loadMore());
  }

  void _scheduleAhead() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _loadAhead();
  });
  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.connectionController.loadPlaylists(
        startIndex: 0,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _playlists = page.playlists;
        _total = page.totalCount;
        _offset = page.nextStartIndex ?? page.playlists.length;
      });
    } on Exception catch (error) {
      if (mounted && request == _request)
        setState(() => _error = error.toString());
    } finally {
      if (mounted && request == _request) {
        setState(() => _loading = false);
        _scheduleAhead();
      }
    }
  }

  Future<void> _loadMore() async {
    if (!_online || _loadingMore || _offset >= _total) return;
    final request = _request;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await widget.connectionController.loadPlaylists(
        startIndex: _offset,
      );
      if (!mounted || request != _request) return;
      final next = page.nextStartIndex ?? _offset + page.playlists.length;
      if (next <= _offset && _offset < page.totalCount)
        throw StateError('The playlist list was incomplete. Try again.');
      setState(() {
        _playlists = [..._playlists, ...page.playlists];
        _total = page.totalCount;
        _offset = next;
      });
    } catch (error) {
      if (mounted && request == _request)
        setState(() => _error = 'Could not load more playlists. Try again.');
    } finally {
      if (mounted && request == _request) {
        setState(() => _loadingMore = false);
        _scheduleAhead();
      }
    }
  }

  Future<void> _open(PlaylistSummary playlist) async {
    final request = ++_request;
    final samePlaylist = _selected?.id == playlist.id;
    setState(() {
      _selected = playlist;
      if (!samePlaylist) {
        _songs = [];
        _tracksReady = false;
        _resetSearch();
        _canEdit = false;
        _detailsReady = false;
        _trackTotal = playlist.trackCount ?? 0;
      }
      _tracksLoading = true;
      _error = null;
    });
    _notifySelection();
    if (!samePlaylist && _scroll.hasClients) _scroll.jumpTo(0);
    final details = widget.connectionController
        .loadPlaylistDetails(playlist.id)
        .then((details) {
          if (mounted && request == _request) {
            _detailsReady = true;
            _acceptSummary(details);
          }
        })
        .catchError((_) {
          /* The original header stays usable if details fail. */
        });
    try {
      final permissions = widget.connectionController
          .canEditPlaylist(playlist.id)
          .catchError((_) => false);
      await for (final page in widget.connectionController.loadPlaylistTracks(
        playlist.id,
        isCancelled: () => !mounted || request != _request,
      )) {
        if (!mounted || request != _request) return;
        setState(() {
          _songs = page.songs;
          _trackTotal = page.totalCount;
          _tracksReady = page.fromCache || page.songs.length >= page.totalCount;
        });
      }
      final canEdit = await permissions;
      if (mounted && request == _request) setState(() => _canEdit = canEdit);
    } on Exception catch (error) {
      if (mounted && request == _request)
        setState(() => _error = error.toString());
    } finally {
      await details;
      if (mounted && request == _request)
        setState(() => _tracksLoading = false);
    }
  }

  Future<void> _openAndPlay(PlaylistSummary playlist) async {
    await _open(playlist);
    if (!mounted ||
        _selected?.id != playlist.id ||
        !_tracksReady ||
        _songs.isEmpty)
      return;
    await _act(
      () =>
          widget.onPlayPlaylist?.call(_songs) ?? widget.onPlaySongs(_songs, 0),
    );
  }

  void _notifySelection() {
    if (_selectionNotificationPending) return;
    _selectionNotificationPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionNotificationPending = false;
      if (mounted) widget.onSelectionChanged?.call(_selected);
    });
  }

  void _acceptSummary(PlaylistSummary playlist) {
    setState(() {
      if (_selected?.id == playlist.id) _selected = playlist;
      _playlists = [
        for (final old in _playlists) old.id == playlist.id ? playlist : old,
      ];
    });
    _notifySelection();
  }

  void _back() {
    _request++;
    setState(() {
      _selected = null;
      _songs = [];
      _resetSearch();
      _tracksLoading = false;
      _loadingMore = false;
      _error = null;
    });
    _notifySelection();
    if (_online) unawaited(_load());
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } on Exception catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _create() async {
    if (_busy || !_online) return;
    final session = widget.connectionController.state.session;
    setState(() {
      _busy = true;
      _dialogOpen = true;
    });
    try {
      final playlist = await showPlaylistNameDialog(
        context,
        widget.connectionController,
      );
      if (mounted) setState(() => _dialogOpen = false);
      if (!mounted ||
          !identical(session, widget.connectionController.state.session) ||
          playlist == null)
        return;
      widget.onPlaylistsChanged?.call();
      await _load();
      if (mounted &&
          identical(session, widget.connectionController.state.session)) {
        await _open(playlist);
      }
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _dialogOpen = false;
        });
    }
  }

  Future<void> _editDetails() async {
    final playlist = _selected;
    if (_busy || !_canEdit || !_detailsReady || playlist == null) return;
    final session = widget.connectionController.state.session;
    setState(() {
      _busy = true;
      _dialogOpen = true;
    });
    try {
      await showPlaylistDetailsDialog(
        context,
        widget.connectionController,
        playlist,
        onSaved: (saved) {
          if (!mounted ||
              !identical(session, widget.connectionController.state.session))
            return;
          _acceptSummary(saved);
          widget.onPlaylistsChanged?.call();
        },
      );
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _dialogOpen = false;
        });
    }
  }

  Future<void> _addSongs() async {
    final playlist = _selected;
    if (_busy || !_canEdit || playlist == null) return;
    final session = widget.connectionController.state.session;
    setState(() {
      _busy = true;
      _dialogOpen = true;
    });
    try {
      final saved = await showAddSongsDialog(
        context,
        widget.connectionController,
        playlist,
        existingItemIds: _songs.map((song) => song.track.id).toSet(),
      );
      if (mounted &&
          saved &&
          identical(session, widget.connectionController.state.session)) {
        await _open(playlist);
        widget.onPlaylistsChanged?.call();
      }
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _dialogOpen = false;
        });
    }
  }

  Future<void> _delete() async {
    final playlist = _selected;
    if (_busy || !_canEdit || playlist == null) return;
    final session = widget.connectionController.state.session;
    final confirmed = await confirmPlaylistChange(
      context,
      title: 'Delete playlist?',
      message:
          'Delete "${playlist.title}" from the server? It will disappear from every device and anyone it is shared with. Your music files stay in your library.',
      action: 'Delete playlist',
    );
    if (!confirmed ||
        !mounted ||
        !identical(session, widget.connectionController.state.session))
      return;
    setState(() => _busy = true);
    try {
      await widget.connectionController.deletePlaylist(playlist.id);
      if (mounted &&
          identical(session, widget.connectionController.state.session)) {
        setState(() => _selected = null);
        _notifySelection();
        widget.onPlaylistsChanged?.call();
        await _load();
      }
    } on Exception catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editEntry(int index, String action) async {
    final playlist = _selected;
    if (_busy || !_canEdit || playlist == null || index >= _songs.length)
      return;
    if (_searchTerms.isNotEmpty && action != 'remove') return;
    final song = _songs[index];
    final entryId = song.entryId;
    if (entryId == null) return;
    final session = widget.connectionController.state.session;
    final entries = _songs.map((song) => song.entryId).toList(growable: false);
    if (action == 'remove') {
      final confirmed = await confirmPlaylistChange(
        context,
        title: 'Remove song?',
        message:
            'Remove "${song.track.title}" from "${playlist.title}"? Your music file stays in your library.',
        action: 'Remove song',
      );
      if (!confirmed ||
          !mounted ||
          !identical(session, widget.connectionController.state.session))
        return;
    }
    setState(() => _busy = true);
    try {
      if (action == 'remove') {
        await widget.connectionController.removePlaylistEntry(
          playlist.id,
          entryId,
        );
      } else {
        await widget.connectionController.movePlaylistEntry(
          playlist.id,
          entryId,
          action == 'up' ? index - 1 : index + 1,
          expectedEntries: entries,
        );
      }
      if (mounted &&
          identical(session, widget.connectionController.state.session)) {
        await _open(playlist);
        widget.onPlaylistsChanged?.call();
      }
    } on Exception catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => TrackSelectionScope(
    child: LayoutBuilder(
      builder: (context, constraints) => GazeSwap(
        alignment: Alignment.topLeft,
        child: KeyedSubtree(
          key: ValueKey(_selected != null),
          child: _buildContent(context, constraints),
        ),
      ),
    ),
  );

  Widget _buildContent(BuildContext context, BoxConstraints constraints) {
    _scroll.smoothingEnabled = !MediaQuery.disableAnimationsOf(context);
    if (!_online)
      return _message(
        'Playlists need a connection',
        'Reconnect to Jellyfin to browse and play your playlists.',
        widget.onConnect,
        'Connect Jellyfin',
      );
    final selected = _selected;
    final playable =
        _online &&
        (_tracksReady || !_tracksLoading) &&
        !_busy &&
        _songs.isNotEmpty;
    // Filtering changes only the view. Playback and mutations keep the original
    // indices so duplicate tracks and hidden neighboring entries remain correct.
    final matchingIndices = _matchingSongIndices;
    final inset = constraints.maxWidth < 600 ? 20.0 : 32.0;
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 24, inset, 24),
          sliver: SliverToBoxAdapter(
            child: AnimatedSize(
              duration: GazeMotion.duration(context),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: GazeSwap(
                alignment: Alignment.topLeft,
                child: KeyedSubtree(
                  key: ValueKey(selected?.id),
                  child: selected == null
                      ? _collectionHeader()
                      : _detailHeader(
                          selected,
                          constraints.maxWidth,
                          playable,
                          matchingIndices.length,
                        ),
                ),
              ),
            ),
          ),
        ),
        if (_tracksLoading ||
            (_busy && !_dialogOpen) ||
            (_loading && _playlists.isNotEmpty))
          const SliverToBoxAdapter(
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (selected == null)
          ..._collectionSlivers(inset, constraints.maxWidth)
        else
          ..._trackSlivers(
            playable,
            inset,
            constraints.maxWidth,
            matchingIndices,
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _collectionHeader() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text('Playlists', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'New playlist',
            onPressed: _busy ? null : _create,
            color: Colors.white,
            icon: const Icon(Icons.add_rounded, size: 26),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh playlists',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text('Your mixes, your moments.'),
    ],
  );

  Widget _detailHeader(
    PlaylistSummary playlist,
    double width,
    bool playable,
    int matchCount,
  ) {
    final compact = width < 620;
    final coverSize = compact
        ? 144.0
        : width > 1000
        ? 224.0
        : 184.0;
    final editable = _canEdit && !_tracksLoading && !_busy;
    final detailsEditable = editable && _detailsReady;
    final duration = _songs.fold<Duration>(
      Duration.zero,
      (total, song) => total + song.track.duration,
    );
    final count = _tracksLoading
        ? playlist.trackCount ?? _songs.length
        : _songs.length;
    final metadata =
        '$count ${count == 1 ? 'song' : 'songs'}${!_tracksLoading && duration.inSeconds > 0 ? ' · ${_durationLabel(duration)}' : ''}';
    final cover = Tooltip(
      message: detailsEditable ? 'Edit playlist image and details' : '',
      child: Semantics(
        button: detailsEditable,
        label: detailsEditable
            ? 'Edit playlist image and details'
            : 'Playlist artwork',
        child: InkWell(
          onTap: detailsEditable ? _editDetails : null,
          borderRadius: BorderRadius.circular(GazeRadii.control),
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: LibraryArtwork(
              connectionController: widget.connectionController,
              itemId: playlist.id,
              imageTag: playlist.imageTag,
              dimension: coverSize,
              iconSize: 64,
              icon: Icons.queue_music_rounded,
            ),
          ),
        ),
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PLAYLIST',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(letterSpacing: 1.8),
        ),
        const SizedBox(height: 12),
        Text(
          playlist.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            fontSize: compact
                ? 30
                : width > 1000
                ? 50
                : 38,
            height: 1.08,
          ),
        ),
        if (playlist.description.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            playlist.description,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 16),
        Text(metadata, style: const TextStyle(color: GazeColors.textPrimary)),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: _busy ? null : _back,
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('All playlists'),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh playlists',
              onPressed: _tracksLoading || _busy ? null : () => _open(playlist),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (compact) ...[
          cover,
          const SizedBox(height: 24),
          details,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              cover,
              const SizedBox(width: 28),
              Expanded(child: details),
            ],
          ),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, constraints) {
            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filled(
                  tooltip: 'Play playlist',
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor:
                        ThemeData.estimateBrightnessForColor(
                              Theme.of(context).colorScheme.primary,
                            ) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                    fixedSize: const Size.square(56),
                    shape: const CircleBorder(),
                  ),
                  onPressed: playable
                      ? () => _act(
                          () =>
                              widget.onPlayPlaylist?.call(_songs) ??
                              widget.onPlaySongs(_songs, 0),
                        )
                      : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 32),
                ),
                const SizedBox(width: 16),
                IconButton(
                  tooltip: 'Edit details',
                  onPressed: detailsEditable ? _editDetails : null,
                  icon: const Icon(Icons.edit_outlined, size: 22),
                ),
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  popUpAnimationStyle: GazeMotion.style(context),
                  tooltip: 'Playlist options',
                  icon: const Icon(Icons.more_horiz_rounded),
                  enabled: !_tracksLoading && !_busy,
                  onSelected: (action) {
                    if (action == 'add') _addSongs();
                    if (action == 'edit') _editDetails();
                    if (action == 'queue')
                      _act(() => widget.onQueueSongs(_songs, false));
                    if (action == 'delete') _delete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'add',
                      enabled: editable,
                      child: const Text('Add songs'),
                    ),
                    PopupMenuItem(
                      value: 'queue',
                      enabled: playable,
                      child: const Text('Add to queue'),
                    ),
                    PopupMenuItem(
                      value: 'edit',
                      enabled: detailsEditable,
                      child: const Text('Edit playlist'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: editable,
                      child: const Text('Delete playlist'),
                    ),
                  ],
                ),
              ],
            );
            if (constraints.maxWidth < 540) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  actions,
                  const SizedBox(height: 16),
                  _playlistSearchField(),
                ],
              );
            }
            return Row(
              children: [
                actions,
                const Spacer(),
                SizedBox(width: 280, child: _playlistSearchField()),
              ],
            );
          },
        ),
        if (!_tracksLoading && !_detailsReady) ...[
          const SizedBox(height: 16),
          const Text(
            'Playlist details could not be loaded. Refresh to edit this playlist.',
          ),
        ],
        if (!_tracksLoading && !_canEdit) ...[
          const SizedBox(height: 16),
          const Text('You have read-only access to this playlist.'),
        ],
        if (_searchTerms.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _tracksLoading
                  ? '$matchCount matches so far'
                  : '$matchCount of ${_songs.length} songs',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ],
    );
  }

  Widget _playlistSearchField() => TextField(
    key: const ValueKey('playlist-search'),
    controller: _search,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: 'Search this playlist',
      prefixIcon: const Icon(Icons.search_rounded, size: 20),
      isDense: true,
      suffixIcon: _search.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Clear playlist search',
              onPressed: _clearSearch,
              icon: const Icon(Icons.close_rounded),
            ),
      filled: true,
      fillColor: Colors.white.withValues(alpha: .07),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GazeRadii.control),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GazeRadii.control),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: .12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GazeRadii.control),
        borderSide: const BorderSide(color: GazeColors.textPrimary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    onChanged: (value) => setState(() {
      final query = value.trim().toLowerCase();
      _searchTerms = query.isEmpty ? const [] : query.split(RegExp(r'\s+'));
    }),
  );

  List<Widget> _collectionSlivers(double inset, double width) {
    if (_loading && _playlists.isEmpty)
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    if (_error != null && _playlists.isEmpty)
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _message('Playlists could not be loaded', _error!, _load),
        ),
      ];
    if (_playlists.isEmpty && _offset >= _total)
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _message(
            'No music playlists yet',
            'Create a playlist here and find it on your other devices.',
            _create,
            'New playlist',
          ),
        ),
      ];
    final columns = ((width - inset * 2) / 220).floor().clamp(1, 8);
    final cardWidth = (width - inset * 2 - (columns - 1) * 20) / columns;
    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: cardWidth + 84,
            crossAxisSpacing: 20,
            mainAxisSpacing: 20,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final playlist = _playlists[index];
            return Semantics(
              button: true,
              label: 'Open ${playlist.title}',
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(GazeRadii.card),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: ValueKey('playlist-card-${playlist.id}'),
                  onTap: () => _open(playlist),
                  onDoubleTap: () => _openAndPlay(playlist),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LibraryArtwork(
                          connectionController: widget.connectionController,
                          itemId: playlist.id,
                          imageTag: playlist.imageTag,
                          dimension: cardWidth - 16,
                          icon: Icons.queue_music_rounded,
                          iconSize: 56,
                        ),
                        const SizedBox(height: 12),
                        MarqueeText(
                          playlist.title,
                          hoverOnly: true,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          playlist.trackCount == null
                              ? 'Playlist'
                              : '${playlist.trackCount} songs',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }, childCount: _playlists.length),
        ),
      ),
      if (_error != null)
        SliverToBoxAdapter(
          child: TextButton(
            onPressed: _loadMore,
            child: const Text('Retry loading playlists'),
          ),
        )
      else if (_loadingMore || _offset < _total)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
    ];
  }

  List<Widget> _trackSlivers(
    bool playable,
    double inset,
    double width,
    List<int> matchingIndices,
  ) {
    // Outgoing rows retain their data during the short exit animation.
    final _songs = List<SongSummary>.of(this._songs);
    final _selected = this._selected;
    if (_error != null)
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _message(
            'Playlist could not be loaded',
            _error!,
            () => _open(_selected!),
          ),
        ),
      ];
    if (_songs.isEmpty && _tracksLoading)
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    if (_songs.isEmpty)
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _message(
            'This playlist is empty',
            'Choose songs from your library to make this playlist your own.',
            _canEdit ? _addSongs : null,
            'Add songs',
          ),
        ),
      ];
    if (matchingIndices.isEmpty)
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _tracksLoading
              ? const Center(child: CircularProgressIndicator())
              : _message(
                  'No matching songs',
                  'Try another title, artist, or album.',
                  _clearSearch,
                  'Clear search',
                ),
        ),
      ];
    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        sliver: SliverToBoxAdapter(
          child: Column(
            children: [
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    const SizedBox(width: 36, child: Text('#')),
                    const SizedBox(width: 64),
                    const Expanded(flex: 5, child: Text('Title')),
                    if (width >= 760) ...[
                      const SizedBox(width: 24),
                      const Expanded(flex: 3, child: Text('Album')),
                    ],
                    const SizedBox(width: 16),
                    const SizedBox(
                      width: 46,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Icon(Icons.schedule_rounded, size: 18),
                      ),
                    ),
                    const SizedBox(width: 68),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        sliver: SliverList.builder(
          itemCount: matchingIndices.length,
          itemBuilder: (context, visibleIndex) {
            final index = matchingIndices[visibleIndex];
            return SongRow(
              key: ValueKey(
                '${_selected!.id}:$index:${_songs[index].track.id}',
              ),
              displayNumber: index + 1,
              song: _songs[index],
              connectionController: widget.connectionController,
              showAlbum: width >= 760,
              onPlay: !playable
                  ? null
                  : (song) => _act(() {
                      final songs = [..._songs];
                      songs[index] = song;
                      return widget.onPlaySongs(songs, index);
                    }),
              extraMenuItems:
                  !_canEdit ||
                      _busy ||
                      _tracksLoading ||
                      _songs[index].entryId == null
                  ? const []
                  : [
                      PopupMenuItem(
                        value: 'up',
                        enabled:
                            _searchTerms.isEmpty &&
                            index > 0 &&
                            _songs.length == _trackTotal,
                        child: const Text('Move up'),
                      ),
                      PopupMenuItem(
                        value: 'down',
                        enabled:
                            _searchTerms.isEmpty &&
                            index + 1 < _songs.length &&
                            _songs.length == _trackTotal,
                        child: const Text('Move down'),
                      ),
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove from playlist'),
                      ),
                    ],
              onExtraAction: (action) => _editEntry(index, action),
              onQueue: !playable
                  ? null
                  : (song, next) =>
                        _act(() => widget.onQueueSongs([song], next)),
            );
          },
        ),
      ),
    ];
  }

  Widget _message(
    String title,
    String message, [
    VoidCallback? action,
    String label = 'Retry',
  ]) => Center(
    child: Padding(
      padding: const EdgeInsets.all(GazeSpacing.xLarge),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: action, child: Text(label)),
          ],
        ],
      ),
    ),
  );
}

String _durationLabel(Duration duration) => duration.inHours > 0
    ? '${duration.inHours} hr ${duration.inMinutes.remainder(60)} min'
    : '${duration.inMinutes} min';
