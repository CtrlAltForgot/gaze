import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../library/artist_credits.dart';
import 'marquee_text.dart';

class ArtistNavigationScope extends InheritedWidget {
  const ArtistNavigationScope({
    required this.onOpenArtist,
    required super.child,
    super.key,
  });
  final ValueChanged<String> onOpenArtist;
  static ValueChanged<String>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ArtistNavigationScope>()
      ?.onOpenArtist;
  @override
  bool updateShouldNotify(ArtistNavigationScope oldWidget) =>
      oldWidget.onOpenArtist != onOpenArtist;
}

/// Individually focusable credits. Overflow rests for five seconds, moves to the
/// end, then glides back home; focusing a link pauses motion and reveals it.
class ArtistLinks extends StatefulWidget {
  const ArtistLinks(
    this.credit, {
    this.style,
    this.hoverOnly = false,
    super.key,
  });
  final String credit;
  final TextStyle? style;
  final bool hoverOnly;
  @override
  State<ArtistLinks> createState() => _ArtistLinksState();
}

class _ArtistLinksState extends State<ArtistLinks> with WidgetsBindingObserver {
  final _scroll = ScrollController();
  Timer? _pause;
  bool _hovered = false, _focused = false, _active = false, _foreground = true;
  int _motion = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ArtistLinks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.credit != oldWidget.credit) {
      _stop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(0);
          _schedule();
        }
      });
    }
  }

  void _stop() {
    _pause?.cancel();
    _motion++;
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.offset);
  }

  void _schedule() {
    _pause?.cancel();
    if (!_active || _focused) return;
    final motion = ++_motion;
    _pause = Timer(const Duration(seconds: 5), () async {
      if (!mounted ||
          motion != _motion ||
          !_scroll.hasClients ||
          _scroll.position.maxScrollExtent < 1)
        return;
      final distance = _scroll.position.maxScrollExtent;
      await _scroll.animateTo(
        distance,
        duration: Duration(
          milliseconds: (distance / 28 * 1000).round().clamp(200, 30000),
        ),
        curve: Curves.linear,
      );
      if (!mounted || motion != _motion) return;
      _pause = Timer(const Duration(milliseconds: 900), () async {
        if (!mounted || motion != _motion || !_scroll.hasClients) return;
        await _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 650),
          curve: Curves.easeInOutCubic,
        );
        if (mounted && motion == _motion) _schedule();
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pause?.cancel();
    _motion++;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = ArtistNavigationScope.maybeOf(context);
    final names = artistCredits(widget.credit);
    if (open == null || names.isEmpty)
      return MarqueeText(
        widget.credit,
        style: widget.style,
        hoverOnly: widget.hoverOnly,
      );
    final active =
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        (!widget.hoverOnly || _hovered);
    if (active != _active) {
      _active = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _stop();
          _schedule();
        }
      });
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          _focused = focused;
          _stop();
          if (!focused) _schedule();
        },
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, name) in names.indexed) ...[
                if (i > 0) Text(' · ', style: widget.style),
                Builder(
                  builder: (linkContext) => Semantics(
                    link: true,
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent &&
                            (event.logicalKey == LogicalKeyboardKey.enter ||
                                event.logicalKey == LogicalKeyboardKey.space)) {
                          open(name);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: InkWell(
                        onTap: () => open(name),
                        onDoubleTap:
                            () {}, // Never bubble a credit double-click to row playback.
                        onFocusChange: (focused) {
                          if (focused)
                            Scrollable.ensureVisible(
                              linkContext,
                              alignment: .5,
                              duration: const Duration(milliseconds: 120),
                            );
                        },
                        borderRadius: BorderRadius.circular(3),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(name, style: widget.style, maxLines: 1),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
