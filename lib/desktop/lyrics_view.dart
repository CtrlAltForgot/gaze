import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/gaze_motion.dart';
import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/track_lyrics.dart';
import '../party/party_controller.dart';
import '../playback/playback_controller.dart';
import 'marquee_text.dart';

/// One playback timeline for the central lyrics page and unboxed Media Mode.
class LyricsView extends StatefulWidget {
  const LyricsView({
    required this.connectionController,
    required this.playbackController,
    required this.onClose,
    this.immersive = false,
    this.partyController,
    super.key,
  });

  final JellyfinConnectionController connectionController;
  final PlaybackController playbackController;
  final VoidCallback onClose;
  final bool immersive;
  final PartyController? partyController;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _scroll = ScrollController();
  final _lineKeys = <GlobalKey>[];
  StreamSubscription<PlaybackSnapshot>? _subscription;
  late PlaybackSnapshot _playback;
  TrackLyrics? _lyrics;
  Timer? _resumeFollowing;
  int _request = 0, _activeLine = -1;
  bool _loading = false, _failed = false, _browsing = false;
  double? _layoutWidth;
  bool _wasActive = false;
  bool _reloadWhenActive = true;
  Object? _loadedIdentity;
  Object? get _identity => widget.partyController?.following == true
      ? widget.partyController!.lyricsIdentity
      : _playback.itemId;

  @override
  void initState() {
    super.initState();
    _playback = widget.playbackController.state;
    _subscription = widget.playbackController.states.listen(_handlePlayback);
    widget.partyController?.addListener(_partyChanged);
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.partyController != widget.partyController) {
      oldWidget.partyController?.removeListener(_partyChanged);
      widget.partyController?.addListener(_partyChanged);
      _partyChanged();
    }
  }

  void _partyChanged() {
    if (!mounted || _identity == _loadedIdentity) return;
    if (!_wasActive) {
      _reloadWhenActive = true;
    } else {
      setState(_load);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active && !_wasActive) {
      if (_reloadWhenActive) {
        _reloadWhenActive = false;
        _load();
      } else {
        _activeLine = _lyrics?.lineAt(_playback.position) ?? -1;
        _followCurrentLine(animate: false);
      }
    }
    _wasActive = active;
  }

  @override
  void dispose() {
    _request++;
    widget.partyController?.removeListener(_partyChanged);
    unawaited(_subscription?.cancel());
    _resumeFollowing?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _load() {
    final request = ++_request;
    final playback = _playback;
    _loadedIdentity = _identity;
    _lyrics = null;
    _lineKeys.clear();
    _activeLine = -1;
    _browsing = false;
    _failed = false;
    _resumeFollowing?.cancel();
    _loading = _loadedIdentity != null;
    if (!_loading) return;
    unawaited(() async {
      try {
        final lyrics = widget.partyController?.following == true
            ? await widget.partyController!.loadLyrics()
            : await widget.connectionController.loadLyrics(
                playback.itemId!,
                title: playback.title,
                artist: playback.artist,
                duration: playback.duration,
              );
        if (!mounted || request != _request) return;
        setState(() {
          _lyrics = lyrics;
          _loading = false;
          _lineKeys.addAll(
            List.generate(lyrics?.lines.length ?? 0, (_) => GlobalKey()),
          );
          _activeLine = lyrics?.lineAt(_playback.position) ?? -1;
        });
        _followCurrentLine(animate: false);
      } catch (_) {
        if (!mounted || request != _request) return;
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }());
  }

  void _handlePlayback(PlaybackSnapshot playback) {
    if (!mounted) return;
    // Engines can report the recording duration after the source starts. Retry
    // with that duration so a lookup without it cannot pin the wrong version.
    final reload =
        _identity != _loadedIdentity ||
        playback.itemId != _playback.itemId ||
        playback.title != _playback.title ||
        playback.artist != _playback.artist ||
        (playback.duration > Duration.zero &&
            (_playback.duration == Duration.zero ||
                (playback.duration - _playback.duration).inSeconds.abs() > 2));
    _playback = playback;
    if (!_wasActive) {
      _reloadWhenActive = _reloadWhenActive || reload;
      return;
    }
    if (reload) {
      setState(_load);
      return;
    }
    final active = _lyrics?.lineAt(playback.position) ?? -1;
    if (active != _activeLine) {
      setState(() => _activeLine = active);
      _followCurrentLine();
    }
  }

  void _followCurrentLine({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _browsing ||
          !_scroll.hasClients ||
          !TickerMode.valuesOf(context).enabled)
        return;
      final lineContext = _activeLine >= 0 && _activeLine < _lineKeys.length
          ? _lineKeys[_activeLine].currentContext
          : null;
      if (lineContext == null) {
        if (_activeLine < 0) _scroll.jumpTo(0);
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          lineContext,
          alignment: .5,
          duration: animate
              ? GazeMotion.duration(context, const Duration(milliseconds: 240))
              : Duration.zero,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _browse() {
    _browsing = true;
    _resumeFollowing?.cancel();
    _resumeFollowing = Timer(const Duration(seconds: 3), () {
      _browsing = false;
      if (mounted) _followCurrentLine();
    });
  }

  Future<void> _seek(Duration start) async {
    _resumeFollowing?.cancel();
    _browsing = false;
    try {
      await widget.playbackController.seek(start);
      if (mounted) _followCurrentLine();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Could not seek to this lyric. Try again.'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.immersive) return _body();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: GazePageFocus(
        active: _wasActive,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Lyrics',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 4),
                        MarqueeText(
                          _playback.title ?? 'Nothing playing',
                          hoverOnly: true,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    tooltip: 'Close lyrics',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: _body(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_identity == null)
      return const _LyricsMessage(
        'Choose a song',
        'Lyrics will appear here while a song is playing.',
      );
    if (_loading)
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    if (_failed)
      return _LyricsMessage(
        'Lyrics could not be loaded',
        'Check your connection and try again.',
        onRetry: () => setState(_load),
      );
    final lyrics = _lyrics;
    if (lyrics == null || lyrics.lines.isEmpty)
      return const _LyricsMessage(
        'No lyrics available',
        'No matching lyrics were found for this song.',
      );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_layoutWidth != constraints.maxWidth) {
          _layoutWidth = constraints.maxWidth;
          _followCurrentLine(animate: false);
        }
        final size = (constraints.maxWidth * .065).clamp(24.0, 36.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!lyrics.hasTiming)
              const Padding(
                padding: EdgeInsets.fromLTRB(0, 12, 0, 8),
                child: Text(
                  'Timing unavailable for this song',
                  style: TextStyle(
                    fontSize: 12,
                    color: GazeColors.textSecondary,
                  ),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, viewport) {
                  final content = Listener(
                    onPointerSignal: (_) => _browse(),
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (event) {
                        if (event is ScrollStartNotification &&
                                event.dragDetails != null ||
                            event is ScrollUpdateNotification &&
                                event.dragDetails != null)
                          _browse();
                        return false;
                      },
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: EdgeInsets.symmetric(
                          horizontal: 0,
                          vertical: lyrics.hasTiming
                              ? viewport.maxHeight * .4
                              : 24,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (
                              var index = 0;
                              index < lyrics.lines.length;
                              index++
                            )
                              _LyricRow(
                                key: _lineKeys[index],
                                line: lyrics.lines[index],
                                active: index == _activeLine,
                                timed: lyrics.hasTiming,
                                fontSize: size,
                                onSeek:
                                    lyrics.hasTiming &&
                                        lyrics.lines[index].start != null
                                    ? () => _seek(lyrics.lines[index].start!)
                                    : null,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                  return ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.white,
                          Colors.white,
                          Colors.transparent,
                        ],
                        stops: [0, .12, .88, 1],
                      ).createShader(bounds),
                      child: content,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LyricRow extends StatefulWidget {
  const _LyricRow({
    required this.line,
    required this.active,
    required this.timed,
    required this.fontSize,
    required this.onSeek,
    super.key,
  });
  final LyricLine line;
  final bool active, timed;
  final double fontSize;
  final VoidCallback? onSeek;
  @override
  State<_LyricRow> createState() => _LyricRowState();
}

class _LyricRowState extends State<_LyricRow> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: widget.active,
    button: widget.onSeek != null,
    child: InkWell(
      onTap: widget.onSeek,
      onHover: (value) => setState(() => _hovered = value),
      onFocusChange: (value) => setState(() => _focused = value),
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 2),
        child: AnimatedDefaultTextStyle(
          duration: GazeMotion.duration(
            context,
            const Duration(milliseconds: 180),
          ),
          style: TextStyle(
            fontFamily: Theme.of(context).textTheme.bodyLarge?.fontFamily,
            fontSize: widget.fontSize,
            fontWeight: FontWeight.w700,
            height: 1.35,
            color: Colors.white.withValues(
              alpha: widget.active || _hovered || _focused
                  ? 1
                  : widget.timed
                  ? .42
                  : .8,
            ),
            decoration: _focused
                ? TextDecoration.underline
                : TextDecoration.none,
          ),
          child: Text(widget.line.text.isEmpty ? '♪' : widget.line.text),
        ),
      ),
    ),
  );
}

class _LyricsMessage extends StatelessWidget {
  const _LyricsMessage(this.title, this.message, {this.onRetry});
  final String title, message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: GazeColors.textSecondary),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
