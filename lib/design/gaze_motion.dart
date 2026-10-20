import 'package:flutter/material.dart';

/// One short motion vocabulary. Actions execute immediately; only presentation
/// animates. Reduced motion removes spatial movement and waiting entirely.
abstract final class GazeMotion {
  static const feedback = Duration(milliseconds: 110);
  static const enter = Duration(milliseconds: 180);
  static const exit = Duration(milliseconds: 130);
  static Duration duration(BuildContext context, [Duration value = enter]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
  static AnimationStyle style(BuildContext context) => AnimationStyle(
    duration: duration(context),
    reverseDuration: duration(context, exit),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
}

/// Small content changes, icons, and detail views retain their outgoing visual
/// until its short exit finishes. The outgoing control cannot receive input.
class GazeSwap extends StatelessWidget {
  const GazeSwap({
    required this.child,
    this.alignment = Alignment.center,
    super.key,
  });
  final Widget child;
  final AlignmentGeometry alignment;
  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: GazeMotion.duration(context),
    reverseDuration: GazeMotion.duration(context, GazeMotion.exit),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(
      alignment: alignment,
      children: [
        for (final old in previous)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeFocus(child: ExcludeSemantics(child: old)),
            ),
          ),
        ?current,
      ],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween(begin: .98, end: 1.0).animate(animation),
        child: child,
      ),
    ),
    child: child,
  );
}

/// A retained page stack: transitions never recreate a library page, lose its
/// scroll position, or duplicate playback controllers. Hidden pages stop ticking.
class GazePageStack extends StatefulWidget {
  const GazePageStack({
    required this.index,
    required this.children,
    this.vertical = false,
    super.key,
  });
  final int index;
  final List<Widget> children;
  final bool vertical;
  @override
  State<GazePageStack> createState() => _GazePageStackState();
}

class _GazePageStackState extends State<GazePageStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation =
      AnimationController(vsync: this, value: 1)..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted)
          setState(() => _outgoing = null);
      });
  int? _outgoing;
  double _direction = 1;
  @override
  void initState() {
    super.initState();
    _animation.value = 1;
  }

  @override
  void didUpdateWidget(GazePageStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _direction = widget.index > oldWidget.index ? 1 : -1;
    _outgoing = oldWidget.index;
    _animation.duration = GazeMotion.duration(
      context,
      _direction > 0 ? GazeMotion.enter : GazeMotion.exit,
    );
    _animation.forward(from: 0);
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    builder: (context, _) {
      final t = Curves.easeOutCubic.transform(_animation.value);
      return Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            Offstage(
              key: ValueKey(i),
              offstage: i != widget.index && i != _outgoing,
              child: TickerMode(
                enabled: i == widget.index,
                child: IgnorePointer(
                  ignoring: i != widget.index,
                  child: ExcludeSemantics(
                    excluding: i != widget.index,
                    child: FocusScope(
                      canRequestFocus: i == widget.index,
                      autofocus: i == widget.index,
                      child: Opacity(
                        opacity: i == widget.index
                            ? t
                            : (i == _outgoing ? 1 - t : 0),
                        child: Transform.translate(
                          offset: widget.vertical
                              ? Offset(
                                  0,
                                  (i == widget.index ? 1 - t : -t) *
                                      12 *
                                      _direction,
                                )
                              : Offset(
                                  (i == widget.index ? 1 - t : -t) *
                                      12 *
                                      _direction,
                                  0,
                                ),
                          child: RepaintBoundary(child: widget.children[i]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// A panel keeps its content through the closing animation; repeated toggles
/// reverse the same animation instead of queueing up or snapping shut.
class GazePanel extends StatefulWidget {
  const GazePanel({
    required this.open,
    required this.width,
    required this.child,
    super.key,
  });
  final bool open;
  final double width;
  final Widget? child;
  @override
  State<GazePanel> createState() => _GazePanelState();
}

class _GazePanelState extends State<GazePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(vsync: this);
  Widget? _content;
  @override
  void initState() {
    super.initState();
    _content = widget.child;
    _animation.value = widget.open ? 1 : 0;
    _animation.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted && !widget.open)
        setState(() => _content = null);
    });
  }

  @override
  void didUpdateWidget(GazePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child != null) _content = widget.child;
    _animation.duration = GazeMotion.duration(context);
    _animation.reverseDuration = GazeMotion.duration(context, GazeMotion.exit);
    if (widget.open != oldWidget.open) {
      if (widget.open) {
        _animation.forward();
      } else {
        _animation.reverse();
      }
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    child: SizedBox(width: widget.width, child: _content),
    builder: (context, child) {
      final t = Curves.easeOutCubic.transform(_animation.value);
      return ClipRect(
        child: Align(
          alignment: Alignment.centerRight,
          widthFactor: t,
          child: IgnorePointer(
            ignoring: !widget.open,
            child: ExcludeSemantics(
              excluding: !widget.open,
              child: Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset((1 - t) * 18, 0),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class GazePress extends StatefulWidget {
  const GazePress({required this.child, this.enabled = true, super.key});
  final Widget child;
  final bool enabled;
  @override
  State<GazePress> createState() => _GazePressState();
}

class _GazePressState extends State<GazePress> {
  bool _hovered = false, _pressed = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() {
      _hovered = false;
      _pressed = false;
    }),
    child: Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: !widget.enabled || MediaQuery.disableAnimationsOf(context)
            ? 1
            : _pressed
            ? .94
            : _hovered
            ? 1.035
            : 1,
        duration: GazeMotion.duration(context, GazeMotion.feedback),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    ),
  );
}

/// Restores keyboard focus inside a retained page when it opens again.
class GazePageFocus extends StatefulWidget {
  const GazePageFocus({required this.active, required this.child, super.key});
  final bool active;
  final Widget child;
  @override
  State<GazePageFocus> createState() => _GazePageFocusState();
}

class _GazePageFocusState extends State<GazePageFocus> {
  final _focus = FocusNode();
  @override
  void didUpdateWidget(GazePageFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _focus, autofocus: widget.active, child: widget.child);
}
