import 'artist_links.dart';
import '../design/gaze_motion.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/playlist_summary.dart';
import '../library/song_summary.dart';

bool _sameAccount(JellyfinConnectionController controller, Object? session) =>
    controller.state.isConnected &&
    identical(controller.state.session, session);

Future<PlaylistSummary?> showPlaylistNameDialog(
  BuildContext context,
  JellyfinConnectionController controller, {
  PlaylistSummary? playlist,
  List<String> itemIds = const [],
}) => showDialog<PlaylistSummary>(
  animationStyle: GazeMotion.style(context),
  context: context,
  barrierDismissible: false,
  builder: (_) => _PlaylistNameDialog(
    controller: controller,
    playlist: playlist,
    itemIds: itemIds,
  ),
);

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.controller,
    this.playlist,
    required this.itemIds,
  });
  final JellyfinConnectionController controller;
  final PlaylistSummary? playlist;
  final List<String> itemIds;
  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.playlist?.title ?? '',
  );
  late final Object? _session = widget.controller.state.session;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final title = _name.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give your playlist a name.');
      return;
    }
    if (!_sameAccount(widget.controller, _session)) {
      setState(
        () => _error =
            'Your connection changed. Close this window and reconnect before saving.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      PlaylistSummary result;
      final playlist = widget.playlist;
      if (playlist == null) {
        result = await widget.controller.createPlaylist(
          title,
          itemIds: widget.itemIds,
        );
      } else {
        await widget.controller.renamePlaylist(playlist.id, title);
        result = PlaylistSummary(
          id: playlist.id,
          title: title,
          trackCount: playlist.trackCount,
          imageTag: playlist.imageTag,
        );
      }
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop(result);
        if (widget.itemIds.length > widget.itemIds.toSet().length &&
            result.trackCount == widget.itemIds.toSet().length) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Saved ${result.trackCount} songs. This server stores repeated songs once in playlists.',
              ),
            ),
          );
        }
      }
    } on Exception catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.playlist == null ? 'New playlist' : 'Rename playlist'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              enabled: !_busy,
              maxLength: 140,
              decoration: const InputDecoration(labelText: 'Playlist name'),
              onSubmitted: (_) => _save(),
            ),
            if (widget.playlist == null)
              Text(
                widget.itemIds.isEmpty
                    ? 'Private playlist · Saved to your account'
                    : '${widget.itemIds.length} songs · Private playlist · Saved to your account',
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(
            _busy
                ? 'Saving…'
                : widget.playlist == null
                ? 'Create playlist'
                : 'Save name',
          ),
        ),
      ],
    ),
  );
}

Future<bool> confirmPlaylistChange(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      animationStyle: GazeMotion.style(context),
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<bool> showAddSongsDialog(
  BuildContext context,
  JellyfinConnectionController controller,
  PlaylistSummary playlist, {
  Set<String> existingItemIds = const {},
}) async =>
    await showDialog<bool>(
      animationStyle: GazeMotion.style(context),
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddSongsDialog(
        controller: controller,
        playlist: playlist,
        existingItemIds: existingItemIds,
        onOpenArtist: ArtistNavigationScope.maybeOf(context),
      ),
    ) ??
    false;

class _AddSongsDialog extends StatefulWidget {
  const _AddSongsDialog({
    required this.controller,
    required this.playlist,
    required this.existingItemIds,
    this.onOpenArtist,
  });
  final JellyfinConnectionController controller;
  final PlaylistSummary playlist;
  final Set<String> existingItemIds;
  final ValueChanged<String>? onOpenArtist;
  @override
  State<_AddSongsDialog> createState() => _AddSongsDialogState();
}

class _AddSongsDialogState extends State<_AddSongsDialog> {
  late final Object? _session = widget.controller.state.session;
  final _selected = <String>{};
  List<SongSummary> _songs = [];
  String _query = '';
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _disposed = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cached = await widget.controller.loadCachedSongs();
      if (!mounted) return;
      if (cached != null) setState(() => _songs = cached.songs);
      SongPage? latest;
      await for (final page in widget.controller.refreshSongs(
        isCancelled: () =>
            _disposed || !_sameAccount(widget.controller, _session),
      )) {
        if (!mounted) return;
        if (!_sameAccount(widget.controller, _session)) return;
        latest = page;
        if (cached == null) setState(() => _songs = page.songs);
      }
      if (mounted &&
          latest != null &&
          _sameAccount(widget.controller, _session))
        setState(() => _songs = latest!.songs);
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _selected.isEmpty) return;
    if (!_sameAccount(widget.controller, _session)) {
      setState(() => _error = 'Reconnect to your account before adding songs.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.addPlaylistSongs(
        widget.playlist.id,
        _selected.toList(growable: false),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (error) {
      if (mounted)
        setState(() {
          _busy = false;
          _error = error.toString();
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _songs
        .where(
          (song) => '${song.track.title} ${song.track.artist} ${song.album}'
              .toLowerCase()
              .contains(_query.toLowerCase()),
        )
        .toList(growable: false);
    final height = (MediaQuery.sizeOf(context).height - 160).clamp(
      240.0,
      520.0,
    );
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        child: SizedBox(
          width: 640,
          height: height,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Add songs to ${widget.playlist.title}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    hintText: 'Search your songs',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      maxLines: 3,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(
                  child: visible.isEmpty
                      ? Center(
                          child: Text(
                            _loading
                                ? 'Loading your songs…'
                                : 'No matching songs.',
                          ),
                        )
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final song = visible[index];
                            final alreadyAdded = widget.existingItemIds
                                .contains(song.track.id);
                            final enabled = !_busy && !alreadyAdded;
                            void toggle() => setState(() {
                              if (!_selected.remove(song.track.id))
                                _selected.add(song.track.id);
                            });
                            return ListTile(
                              leading: Checkbox(
                                value: _selected.contains(song.track.id),
                                onChanged: enabled ? (_) => toggle() : null,
                              ),
                              title: Text(
                                song.track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (widget.onOpenArtist != null)
                                    ArtistNavigationScope(
                                      onOpenArtist: (name) {
                                        if (_busy) return;
                                        Navigator.of(context).pop(false);
                                        widget.onOpenArtist!(name);
                                      },
                                      child: ArtistLinks(
                                        song.track.artist,
                                        hoverOnly: true,
                                      ),
                                    )
                                  else
                                    Text(
                                      song.track.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  if (alreadyAdded)
                                    const Text('Already in playlist'),
                                ],
                              ),
                              onTap: enabled ? toggle : null,
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: Text('${_selected.length} selected')),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy || _selected.isEmpty ? null : _save,
                      child: Text(_busy ? 'Saving…' : 'Add songs'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showAddToPlaylistDialog(
  BuildContext context,
  JellyfinConnectionController controller,
  List<String> itemIds,
) async {
  final saved = await showDialog<String>(
    animationStyle: GazeMotion.style(context),
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _AddToPlaylistDialog(controller: controller, itemIds: itemIds),
  );
  if (context.mounted && saved != null)
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(saved)));
}

class _AddToPlaylistDialog extends StatefulWidget {
  const _AddToPlaylistDialog({required this.controller, required this.itemIds});
  final JellyfinConnectionController controller;
  final List<String> itemIds;
  @override
  State<_AddToPlaylistDialog> createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<_AddToPlaylistDialog> {
  late final Object? _session = widget.controller.state.session;
  List<PlaylistSummary> _playlists = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      var offset = 0;
      final playlists = <PlaylistSummary>[];
      while (mounted && _sameAccount(widget.controller, _session)) {
        final page = await widget.controller.loadPlaylists(startIndex: offset);
        if (!mounted) return;
        if (!_sameAccount(widget.controller, _session)) {
          setState(() {
            _playlists = [];
            _error = 'Your account changed. Close this window and try again.';
          });
          return;
        }
        playlists.addAll(page.playlists);
        setState(() => _playlists = List.unmodifiable(playlists));
        final next = page.nextStartIndex ?? offset + page.playlists.length;
        if (next >= page.totalCount) break;
        if (next <= offset) throw StateError('Could not load your playlists.');
        offset = next;
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'Could not load your playlists. Close this window and try again.',
        );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(PlaylistSummary playlist) async {
    if (_busy) return;
    if (!_sameAccount(widget.controller, _session)) {
      setState(() => _error = 'Reconnect to your account before saving.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = <String>{};
      await for (final page in widget.controller.loadPlaylistTracks(
        playlist.id,
        isCancelled: () =>
            !mounted || !_sameAccount(widget.controller, _session),
      )) {
        existing.addAll(page.songs.map((song) => song.track.id));
      }
      if (!mounted || !_sameAccount(widget.controller, _session)) return;
      final additions = widget.itemIds
          .where((id) => !existing.contains(id))
          .toSet()
          .toList(growable: false);
      if (additions.isEmpty) {
        Navigator.of(context).pop('Already in ${playlist.title}');
        return;
      }
      await widget.controller.addPlaylistSongs(playlist.id, additions);
      if (mounted) Navigator.of(context).pop('Saved to ${playlist.title}');
    } on Exception catch (error) {
      if (mounted)
        setState(() {
          _busy = false;
          _error = error.toString();
        });
    }
  }

  Future<void> _create() async {
    if (_busy || !_sameAccount(widget.controller, _session)) return;
    final playlist = await showPlaylistNameDialog(
      context,
      widget.controller,
      itemIds: widget.itemIds,
    );
    if (mounted && playlist != null)
      Navigator.of(context).pop('Saved to ${playlist.title}');
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Add to playlist'),
      content: SizedBox(
        width: 480,
        height: (MediaQuery.sizeOf(context).height - 220).clamp(180.0, 400.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New playlist'),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: _playlists.isEmpty
                  ? Center(
                      child: Text(
                        _loading
                            ? 'Loading your playlists…'
                            : 'Create your first playlist above.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: _playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = _playlists[index];
                        return ListTile(
                          enabled: !_busy,
                          title: Text(
                            playlist.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _add(playlist),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
