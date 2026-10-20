import 'artist_links.dart';
import '../design/gaze_motion.dart';
import 'marquee_text.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/song_summary.dart';
import 'playlist_dialogs.dart';
import 'library_artwork.dart';
import 'track_selection.dart';

export 'library_artwork.dart';

class SongRow extends StatefulWidget {
  const SongRow({
    required this.song,
    required this.connectionController,
    required this.showAlbum,
    this.onPlay,
    this.displayNumber,
    this.onQueue,
    this.extraMenuItems = const [],
    this.onExtraAction,
    super.key,
  });
  final SongSummary song;
  final JellyfinConnectionController connectionController;
  final bool showAlbum;
  final int? displayNumber;
  final void Function(SongSummary)? onPlay;
  final void Function(SongSummary, bool next)? onQueue;
  final List<PopupMenuEntry<String>> extraMenuItems;
  final ValueChanged<String>? onExtraAction;
  @override
  State<SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<SongRow> {
  late Future<Uint8List?> _artwork;
  StreamSubscription<JellyfinConnectionState>? _subscription;
  bool _online = false;
  void _listen() {
    _online = widget.connectionController.state.isConnected;
    _subscription = widget.connectionController.states.listen((state) {
      if (mounted && _online != state.isConnected) {
        _online = state.isConnected;
        setState(() {
          _load();
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _load() => _artwork = widget.song.artworkBytes != null
      ? Future.value(widget.song.artworkBytes)
      : widget.connectionController.loadArtwork(
          widget.song.albumId,
          widget.song.imageTag,
        );
  @override
  void initState() {
    super.initState();
    _load();
    _listen();
  }

  @override
  void didUpdateWidget(SongRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectionController != widget.connectionController) {
      unawaited(_subscription?.cancel());
      _listen();
    }
    if (oldWidget.song.track.id != widget.song.track.id ||
        oldWidget.song.imageTag != widget.song.imageTag ||
        oldWidget.connectionController != widget.connectionController)
      _load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _artwork,
    builder: (context, snapshot) {
      final song = SongSummary(
        track: widget.song.track,
        album: widget.song.album,
        albumId: widget.song.albumId,
        entryId: widget.song.entryId,
        imageTag: widget.song.imageTag,
        artworkBytes: snapshot.data,
      );
      final items = <PopupMenuEntry<String>>[
        PopupMenuItem(
          value: 'play',
          enabled: widget.onPlay != null,
          child: const Text('Play'),
        ),
        PopupMenuItem(
          value: 'next',
          enabled: widget.onQueue != null,
          child: const Text('Play next'),
        ),
        PopupMenuItem(
          value: 'queue',
          enabled: widget.onQueue != null,
          child: const Text('Add to queue'),
        ),
        PopupMenuItem(
          value: 'playlist',
          enabled: widget.onPlay != null,
          child: const Text('Add to playlist…'),
        ),
        ...widget.extraMenuItems,
      ];
      void action(String value) {
        if (value == 'play') {
          widget.onPlay?.call(song);
        } else if (value == 'playlist') {
          showAddToPlaylistDialog(context, widget.connectionController, [
            song.track.id,
          ]);
        } else if (value == 'next' || value == 'queue') {
          widget.onQueue?.call(song, value == 'next');
        } else {
          widget.onExtraAction?.call(value);
        }
      }

      Future<void> menu(Offset position) async {
        final overlay =
            Overlay.of(context).context.findRenderObject()! as RenderBox;
        final result = await showMenu<String>(
          popUpAnimationStyle: GazeMotion.style(context),
          context: context,
          position: RelativeRect.fromRect(
            overlay.globalToLocal(position) & const Size(1, 1),
            Offset.zero & overlay.size,
          ),
          items: items,
        );
        if (result != null && context.mounted) action(result);
      }

      return SelectableTrack(
        identity: widget.key ?? song.entryId ?? song.track.id,
        onPlay: widget.onPlay == null ? null : () => widget.onPlay!(song),
        onContextMenu: menu,
        builder: (context, active) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Row(
            children: [
              if (widget.displayNumber != null)
                SizedBox(
                  width: 36,
                  child: GazeSwap(
                    child: active
                        ? IconButton(
                            key: const ValueKey('play'),
                            tooltip: 'Play ${song.track.title}',
                            padding: EdgeInsets.zero,
                            onPressed: widget.onPlay == null
                                ? null
                                : () => widget.onPlay!(song),
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                              size: 22,
                            ),
                          )
                        : Text(
                            '${widget.displayNumber}',
                            key: const ValueKey('number'),
                            style: const TextStyle(fontSize: 13),
                          ),
                  ),
                ),
              SizedBox.square(
                dimension: 48,
                child: Stack(
                  children: [
                    LibraryArtwork(
                      connectionController: widget.connectionController,
                      bytes: snapshot.data,
                      itemId: song.albumId ?? song.track.id,
                      imageTag: song.imageTag,
                      dimension: 48,
                    ),
                    if (widget.displayNumber == null)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !active,
                          child: AnimatedOpacity(
                            opacity: active ? 1 : 0,
                            duration: GazeMotion.duration(
                              context,
                              GazeMotion.feedback,
                            ),
                            child: Material(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                              child: IconButton(
                                tooltip: 'Play ${song.track.title}',
                                onPressed: widget.onPlay == null
                                    ? null
                                    : () => widget.onPlay!(song),
                                icon: const Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      song.track.title,
                      hoverOnly: true,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    ArtistLinks(song.track.artist, hoverOnly: true),
                  ],
                ),
              ),
              if (widget.showAlbum) ...[
                const SizedBox(width: 24),
                Expanded(
                  flex: 3,
                  child: MarqueeText(song.album, hoverOnly: true),
                ),
              ],
              const SizedBox(width: 16),
              SizedBox(
                width: 46,
                child: Text(
                  '${song.track.duration.inMinutes}:${song.track.duration.inSeconds.remainder(60).toString().padLeft(2, '0')}',
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                excluding: !active,
                child: IgnorePointer(
                  ignoring: !active,
                  child: AnimatedOpacity(
                    duration: GazeMotion.duration(context, GazeMotion.feedback),
                    opacity: active ? 1 : 0,
                    child: PopupMenuButton<String>(
                      popUpAnimationStyle: GazeMotion.style(context),
                      tooltip: 'Queue options for ${song.track.title}',
                      icon: const Icon(Icons.more_horiz_rounded, size: 22),
                      onSelected: action,
                      itemBuilder: (_) => items,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
