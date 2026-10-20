import 'artist_links.dart';
import '../design/gaze_motion.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_queue_controller.dart';
import 'library_artwork.dart';
import 'marquee_text.dart';
import 'playback_controls.dart';

class MediaModeArtwork extends StatefulWidget {
  const MediaModeArtwork({
    required this.child,
    required this.onExpand,
    super.key,
  });
  final Widget child;
  final VoidCallback? onExpand;
  @override
  State<MediaModeArtwork> createState() => _MediaModeArtworkState();
}

class _MediaModeArtworkState extends State<MediaModeArtwork> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Stack(
      children: [
        widget.child,
        if (widget.onExpand != null)
          Positioned(
            top: 0,
            left: 0,
            child: Focus(
              onFocusChange: (value) => setState(() => _focused = value),
              child: AnimatedOpacity(
                duration: GazeMotion.duration(context, GazeMotion.feedback),
                opacity: _hovered || _focused ? 1 : 0,
                child: IconButton.filledTonal(
                  tooltip: 'Open Media Mode',
                  onPressed: widget.onExpand,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(28, 28),
                    maximumSize: const Size(28, 28),
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.black.withValues(alpha: .65),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 23),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class MediaMode extends StatelessWidget {
  const MediaMode({
    required this.connection,
    required this.playback,
    required this.queue,
    required this.onClose,
    required this.motionEnabled,
    required this.onToggleMotion,
    required this.onLyrics,
    this.lyrics,
    this.active = true,
    super.key,
  });
  final JellyfinConnectionController connection;
  final PlaybackController playback;
  final PlaybackQueueController queue;
  final VoidCallback onClose, onToggleMotion, onLyrics;
  final bool motionEnabled;
  final Widget? lyrics;
  final bool active;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
    child: GazePageFocus(
      active: active,
      child: StreamBuilder<PlaybackQueueState>(
        stream: queue.states,
        initialData: queue.state,
        builder: (context, queueSnapshot) => StreamBuilder<PlaybackSnapshot>(
          stream: playback.states,
          initialData: playback.state,
          builder: (context, snapshot) {
            final state = snapshot.data ?? playback.state;
            final q = queueSnapshot.data ?? queue.state;
            final current = q.currentIndex >= 0
                ? q.items[q.currentIndex]
                : null;
            final playing =
                state.status == PlaybackStatus.playing ||
                state.status == PlaybackStatus.buffering;
            final hasTrack = state.title != null;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back to library',
                        onPressed: onClose,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'MEDIA MODE',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Semantics(
                        toggled: motionEnabled,
                        child: TextButton.icon(
                          onPressed: onToggleMotion,
                          style: TextButton.styleFrom(
                            foregroundColor: GazeColors.textPrimary,
                          ),
                          icon: Icon(
                            motionEnabled
                                ? Icons.toggle_on_rounded
                                : Icons.toggle_off_outlined,
                            size: 24,
                          ),
                          label: Text(
                            'Background motion: ${motionEnabled ? 'On' : 'Off'}',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: lyrics == null ? 'Show lyrics' : 'Hide lyrics',
                        onPressed: onLyrics,
                        icon: const Icon(Icons.lyrics_outlined),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final compact = box.maxWidth < 900;
                      final padding = compact ? 24.0 : 48.0;
                      final artSize = math.max(
                        120.0,
                        math.min(
                          math.min(
                            box.maxWidth * (compact ? .40 : .46),
                            box.maxHeight - padding * 2,
                          ),
                          680.0,
                        ),
                      );
                      return Padding(
                        padding: EdgeInsets.all(padding),
                        child: Row(
                          children: [
                            SizedBox(
                              width: artSize,
                              height: artSize,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: .25,
                                      ),
                                      blurRadius: 32,
                                      offset: const Offset(0, 16),
                                    ),
                                  ],
                                ),
                                child: LibraryArtwork(
                                  connectionController: connection,
                                  dimension: artSize,
                                  bytes: state.artworkBytes,
                                  itemId: current?.artworkId,
                                  imageTag: current?.artworkTag,
                                  iconSize: 100,
                                ),
                              ),
                            ),
                            SizedBox(width: compact ? 28 : 56),
                            Expanded(
                              child: GazeSwap(
                                child: KeyedSubtree(
                                  key: ValueKey(lyrics != null),
                                  child:
                                      lyrics ??
                                      SingleChildScrollView(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'NOW PLAYING',
                                              style: TextStyle(
                                                fontSize: 11,
                                                letterSpacing: 2,
                                                color: GazeColors.textPrimary
                                                    .withValues(alpha: .6),
                                              ),
                                            ),
                                            const SizedBox(height: 18),
                                            MarqueeText(
                                              state.title ?? 'Choose a song',
                                              style: TextStyle(
                                                fontSize: compact ? 30 : 44,
                                                fontWeight: FontWeight.w700,
                                                color: GazeColors.textPrimary,
                                                letterSpacing: -1,
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            ArtistLinks(
                                              state.artist ??
                                                  'Your library, up close.',
                                              style: TextStyle(
                                                fontSize: compact ? 18 : 23,
                                              ),
                                            ),
                                            const SizedBox(height: 36),
                                            PlaybackControls(
                                              large: true,
                                              playing: playing,
                                              shuffleEnabled: q.shuffleEnabled,
                                              repeatMode: q.repeatMode,
                                              onShuffle: () => queue.setShuffle(
                                                !q.shuffleEnabled,
                                              ),
                                              onPrevious:
                                                  q.hasPrevious ||
                                                      (hasTrack &&
                                                          state.position >
                                                              PlaybackQueueController
                                                                  .previousRestartThreshold)
                                                  ? queue.previous
                                                  : null,
                                              onPlayPause: hasTrack
                                                  ? playing
                                                        ? playback.pause
                                                        : playback.play
                                                  : null,
                                              onNext: q.hasNext
                                                  ? queue.next
                                                  : null,
                                              onRepeat: queue.cycleRepeatMode,
                                            ),
                                            const SizedBox(height: 20),
                                            SliderTheme(
                                              data: SliderTheme.of(context)
                                                  .copyWith(
                                                    trackHeight: 3,
                                                    thumbShape:
                                                        const RoundSliderThumbShape(
                                                          enabledThumbRadius: 5,
                                                        ),
                                                  ),
                                              child: Slider(
                                                value: state
                                                    .position
                                                    .inMilliseconds
                                                    .clamp(
                                                      0,
                                                      math.max(
                                                        1,
                                                        state
                                                            .duration
                                                            .inMilliseconds,
                                                      ),
                                                    )
                                                    .toDouble(),
                                                max: math
                                                    .max(
                                                      1,
                                                      state
                                                          .duration
                                                          .inMilliseconds,
                                                    )
                                                    .toDouble(),
                                                onChanged:
                                                    hasTrack &&
                                                        state.duration >
                                                            Duration.zero
                                                    ? (value) => playback.seek(
                                                        Duration(
                                                          milliseconds: value
                                                              .round(),
                                                        ),
                                                      )
                                                    : null,
                                              ),
                                            ),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text(
                                                  _time(state.position),
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                                Text(
                                                  _time(state.duration),
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 24),
                                            SizedBox(
                                              width: 180,
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons.volume_up_outlined,
                                                    size: 18,
                                                  ),
                                                  Expanded(
                                                    child: Slider(
                                                      value: state.volume.clamp(
                                                        0,
                                                        1,
                                                      ),
                                                      onChanged:
                                                          playback.setVolume,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  static String _time(Duration value) =>
      '${value.inMinutes}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}
