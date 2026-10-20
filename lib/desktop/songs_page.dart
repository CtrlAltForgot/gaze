import 'dart:async';
import 'package:flutter/material.dart';
import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/song_summary.dart';
import 'smooth_scroll_controller.dart';
import 'track_selection.dart';
import 'song_row.dart';

class SongsPage extends StatefulWidget {
  const SongsPage({
    required this.connectionController,
    required this.onConnect,
    required this.onPlaySongs,
    required this.onQueueSong,
    super.key,
  });
  final JellyfinConnectionController connectionController;
  final VoidCallback onConnect;
  final Future<void> Function(List<SongSummary>, int) onPlaySongs;
  final Future<void> Function(SongSummary, bool next) onQueueSong;
  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage> {
  final SmoothScrollController _scrollController = SmoothScrollController();
  StreamSubscription<JellyfinConnectionState>? _connectionSubscription;
  List<SongSummary> _songs = [];
  int _totalCount = 0;
  int _refreshedCount = 0;
  int _refreshTotal = 0;
  int _request = 0;
  bool _refreshing = false;
  bool _saved = false;
  bool _retrying = false;
  String? _error;
  String? _account;
  bool get _online => widget.connectionController.state.isConnected;
  bool get _browse => widget.connectionController.state.canBrowseLibrary;
  bool get _canPlay => _online;
  String? get _currentAccount {
    final state = widget.connectionController.state;
    return state.serverInfo == null || state.session == null
        ? null
        : '${state.serverInfo!.id}:${state.session!.userId}';
  }

  @override
  void initState() {
    super.initState();
    _account = _currentAccount;
    _connectionSubscription = widget.connectionController.states.listen((
      state,
    ) {
      if (!mounted) return;
      _request++;
      if (state.canBrowseLibrary) {
        final account = _currentAccount;
        if (account != _account) {
          _songs = [];
          _saved = false;
          _totalCount = 0;
        }
        _account = account;
        unawaited(_load());
      } else {
        setState(() {
          _refreshing = false;
          if (state.status != JellyfinConnectionStatus.connecting) {
            _songs = [];
            _saved = false;
            _totalCount = 0;
          }
        });
      }
    });
    if (_browse) unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    unawaited(_connectionSubscription?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    bool active() => mounted && request == _request;
    setState(() {
      _refreshing = true;
      _error = null;
      _refreshedCount = 0;
      _refreshTotal = 0;
    });
    try {
      final cached = await widget.connectionController.loadCachedSongs();
      if (!active()) return;
      if (cached != null)
        setState(() {
          _songs = cached.songs;
          _totalCount = cached.totalCount;
          _saved = true;
        });
      if (!_online) return;
      SongPage? latest;
      await for (final page in widget.connectionController.refreshSongs(
        isCancelled: () => !active(),
      )) {
        if (!active()) return;
        latest = page;
        setState(() {
          _refreshedCount = page.songs.length;
          _refreshTotal = page.totalCount;
          if (!_saved) {
            _songs = page.songs;
            _totalCount = page.totalCount;
          }
        });
      }
      if (active() && latest != null && _online)
        setState(() {
          _songs = latest!.songs;
          _totalCount = latest.totalCount;
          _saved = false;
        });
    } on Exception catch (error) {
      if (active()) setState(() => _error = error.toString());
    } finally {
      if (active()) setState(() => _refreshing = false);
    }
  }

  Future<void> _retry() async {
    if (_retrying || _refreshing) return;
    setState(() => _retrying = true);
    try {
      if (_online) {
        await _load();
      } else {
        await widget.connectionController.reconnect();
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
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

  @override
  Widget build(BuildContext context) =>
      TrackSelectionScope(child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    _scrollController.smoothingEnabled = !MediaQuery.disableAnimationsOf(
      context,
    );
    final loadingCaption = _saved
        ? 'Updating library…'
        : _refreshedCount == 0
        ? 'Loading your library…'
        : 'Loading $_refreshedCount of $_refreshTotal songs…';
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
                      'Songs',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: GazeSpacing.xSmall),
                    Text(
                      _songs.isEmpty && _refreshing
                          ? loadingCaption
                          : '${_totalCount == 1 ? '1 song' : '$_totalCount songs'}${_refreshing ? ' · $loadingCaption' : ''}',
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh songs',
                onPressed: _refreshing || _retrying || !_browse ? null : _retry,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        if (_refreshing) const LinearProgressIndicator(minHeight: 2),
        if ((_browse && !_online) || _error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: GazeSpacing.xLarge,
              vertical: GazeSpacing.small,
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_off_outlined, size: 20),
                const SizedBox(width: GazeSpacing.small),
                Expanded(
                  child: Text(
                    !_online
                        ? 'Offline — showing saved song details. Streaming is unavailable.'
                        : 'Could not refresh songs. ${_songs.isEmpty ? '' : 'Your loaded songs are still here. '}${_error!}',
                  ),
                ),
                TextButton(
                  onPressed: _refreshing || _retrying ? null : _retry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _message(
    String title,
    String message, {
    VoidCallback? action,
    String label = 'Retry',
  }) => Center(
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
          const SizedBox(height: GazeSpacing.small),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: GazeSpacing.medium),
            FilledButton(onPressed: action, child: Text(label)),
          ],
        ],
      ),
    ),
  );
  Widget _body() {
    if (!_browse && !_retrying)
      return _message(
        'Connect your Jellyfin library',
        'Connect before browsing songs.',
        action: widget.onConnect,
        label: 'Connect Jellyfin',
      );
    if (_songs.isEmpty && (_refreshing || _retrying))
      return const Center(child: CircularProgressIndicator());
    if (_songs.isEmpty && !_online)
      return _message(
        'No saved songs yet',
        'Connect to Jellyfin once to save your song library on this device.',
      );
    if (_songs.isEmpty && _error != null)
      return _message('Songs could not be loaded', _error!, action: _retry);
    if (_songs.isEmpty)
      return _message(
        'No songs found',
        'Jellyfin returned no songs for this account.',
      );
    return LayoutBuilder(
      builder: (context, constraints) => ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(
          horizontal: GazeSpacing.xLarge,
          vertical: GazeSpacing.small,
        ),
        itemCount: _songs.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: Colors.white.withValues(alpha: .10)),
        itemBuilder: (context, index) => SongRow(
          key: ValueKey(_songs[index].track.id),
          song: _songs[index],
          connectionController: widget.connectionController,
          showAlbum: constraints.maxWidth >= 760,
          onPlay: !_canPlay
              ? null
              : (song) => _act(() {
                  final songs = [..._songs];
                  songs[index] = song;
                  return widget.onPlaySongs(songs, index);
                }),
          onQueue: !_canPlay
              ? null
              : (song, next) => _act(() => widget.onQueueSong(song, next)),
        ),
      ),
    );
  }
}
