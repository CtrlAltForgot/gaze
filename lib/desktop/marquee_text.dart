import 'dart:async';
import 'package:flutter/material.dart';

/// A resting title, followed by a seamless pass back to its starting position.
class MarqueeText extends StatefulWidget {
  const MarqueeText(this.text, {this.style, this.hoverOnly = false, super.key});
  final String text;
  final TextStyle? style;
  final bool hoverOnly;
  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _motion = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _motion.value = 0;
        _schedule();
      }
    });
  Timer? _pause;
  double _distance = 0;
  bool _hovered = false;
  bool _visible = true;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _motion.value = 0;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _reset();
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (mounted) setState(_reset);
  }

  void _reset() {
    _pause?.cancel();
    _motion.stop();
    _motion.value = 0;
  }

  void _schedule() {
    _pause?.cancel();
    if (!_enabled || _distance <= 0) return;
    _pause = Timer(const Duration(seconds: 5), () {
      if (mounted && _enabled) {
        _motion.duration = Duration(
          milliseconds: (_distance / 28 * 1000).round(),
        );
        _motion.forward(from: 0);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pause?.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final active =
        _visible &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        (!widget.hoverOnly || _hovered);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          final height = painter.height;
          painter.dispose();
          final overflow =
              constraints.hasBoundedWidth && width > constraints.maxWidth + 1;
          final distance = overflow ? width + 48 : 0.0;
          final enabled = active && overflow;
          if (distance != _distance || enabled != _enabled) {
            _distance = distance;
            _enabled = enabled;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _reset();
              _schedule();
            });
          }
          if (!enabled)
            return Text(
              widget.text,
              style: widget.style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          final copies = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.text, style: style, maxLines: 1),
              const SizedBox(width: 48),
              RichText(
                text: TextSpan(text: widget.text, style: style),
                textDirection: direction,
                textScaler: scaler,
                maxLines: 1,
              ),
            ],
          );
          return Semantics(
            label: widget.text,
            excludeSemantics: true,
            child: RepaintBoundary(
              child: ClipRect(
                child: SizedBox(
                  height: height,
                  child: OverflowBox(
                    alignment: AlignmentDirectional.centerStart,
                    maxWidth: double.infinity,
                    child: AnimatedBuilder(
                      animation: _motion,
                      child: copies,
                      builder: (_, child) => Transform.translate(
                        offset: Offset(
                          (direction == TextDirection.ltr ? -1 : 1) *
                              _distance *
                              _motion.value,
                          0,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
