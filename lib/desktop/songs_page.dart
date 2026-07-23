import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/song_summary.dart';
import 'smooth_scroll_controller.dart';

class SongsPage extends StatefulWidget {
  const SongsPage({
    required this.connectionController,
    required this.onConnect,
    required this.onPlaySongs,
    super.key,
  });

  final JellyfinConnectionController connectionController;
  final VoidCallback onConnect;
  final Future<void> Function(List<SongSummary> songs, int startIndex)
  onPlaySongs;

  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage> {
  static const _pageSize = 500;

  final SmoothScrollController _scrollController = SmoothScrollController();
  final List<SongSummary> _songs = [];
  int _totalCount = 0;
  bool _loading = false;
  String? _error;

  bool get _connected => widget.connectionController.state.isConnected;

  @override
  void initState() {
    super.initState();
    if (_connected) {
      _loadFirstPage();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
      _songs.clear();
      _totalCount = 0;
    });
    try {
      while (mounted) {
        final page = await widget.connectionController.loadSongs(
          startIndex: _songs.length,
          limit: _pageSize,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _songs.addAll(page.songs);
          _totalCount = page.totalCount;
        });
        if (page.songs.isEmpty || _songs.length >= _totalCount) {
          break;
        }
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
    _scrollController.smoothingEnabled = !MediaQuery.disableAnimationsOf(
      context,
    );
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
              Text('Songs', style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: GazeSpacing.xSmall),
              Text(
                _loading
                    ? _totalCount > 0
                          ? 'Loading ${_songs.length} of $_totalCount songs…'
                          : 'Loading your library…'
                    : _totalCount == 1
                    ? '1 song'
                    : '$_totalCount songs',
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (!_connected) {
      return _SongsMessage(
        icon: Icons.cloud_outlined,
        title: 'Connect your Jellyfin library',
        message: 'Connect before browsing songs.',
        buttonLabel: 'Connect Jellyfin',
        onPressed: widget.onConnect,
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _songs.isEmpty) {
      return _SongsMessage(
        icon: Icons.cloud_off_outlined,
        title: 'Songs could not be loaded',
        message: _error!,
        buttonLabel: 'Try again',
        onPressed: _loadFirstPage,
      );
    }
    if (_songs.isEmpty) {
      return const _SongsMessage(
        icon: Icons.music_note_rounded,
        title: 'No songs found',
        message: 'Jellyfin returned no songs for this account.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final showAlbum = constraints.maxWidth >= 760;
        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                GazeSpacing.xLarge,
                GazeSpacing.small,
                GazeSpacing.xLarge,
                0,
              ),
              sliver: SliverList.separated(
                itemCount: _songs.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: Colors.white.withValues(alpha: .10),
                ),
                itemBuilder: (context, index) {
                  final song = _songs[index];
                  return _SongRow(
                    song: song,
                    showAlbum: showAlbum,
                    onPlay: () => widget.onPlaySongs(_songs, index),
                  );
                },
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.only(bottom: GazeSpacing.xLarge),
            ),
          ],
        );
      },
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.song,
    required this.showAlbum,
    required this.onPlay,
  });

  final SongSummary song;
  final bool showAlbum;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPlay,
      borderRadius: BorderRadius.circular(GazeRadii.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: GazeSpacing.small),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(GazeRadii.control),
              child: ColoredBox(
                color: GazeColors.surfaceRaised,
                child: SizedBox.square(
                  dimension: 52,
                  child: song.artworkBytes == null
                      ? const Icon(
                          Icons.music_note_rounded,
                          color: GazeColors.textSecondary,
                        )
                      : Image.memory(song.artworkBytes!, fit: BoxFit.cover),
                ),
              ),
            ),
            const SizedBox(width: GazeSpacing.medium),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: GazeSpacing.xSmall),
                  Text(
                    song.track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (showAlbum) ...[
              const SizedBox(width: GazeSpacing.large),
              Expanded(
                flex: 3,
                child: Text(
                  song.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(width: GazeSpacing.large),
            Text(_formatDuration(song.track.duration)),
            const SizedBox(width: GazeSpacing.small),
            const Icon(Icons.play_arrow_rounded),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _SongsMessage extends StatelessWidget {
  const _SongsMessage({
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
