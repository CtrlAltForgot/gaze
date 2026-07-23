import 'dart:async';

import 'package:flutter/widgets.dart';

class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  bool smoothingEnabled = true;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      smoothingEnabled: () => smoothingEnabled,
    );
  }
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    required this.smoothingEnabled,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final bool Function() smoothingEnabled;
  double? _wheelTarget;
  int _animationGeneration = 0;

  @override
  void pointerScroll(double delta) {
    if (!smoothingEnabled()) {
      super.pointerScroll(delta);
      return;
    }
    if (delta == 0 || !hasContentDimensions) {
      return;
    }
    final target = ((_wheelTarget ?? pixels) + delta).clamp(
      minScrollExtent,
      maxScrollExtent,
    );
    if (target == pixels) {
      _wheelTarget = null;
      return;
    }
    _wheelTarget = target;
    final generation = ++_animationGeneration;
    unawaited(
      animateTo(
        target,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
      ).whenComplete(() {
        if (generation == _animationGeneration) {
          _wheelTarget = null;
        }
      }),
    );
  }
}
