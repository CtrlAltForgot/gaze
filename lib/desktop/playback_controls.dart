import 'package:flutter/material.dart';

import '../playback/playback_queue_controller.dart';
import '../design/gaze_motion.dart';

/// Compact transport visuals with full-size pointer and keyboard targets.
class PlaybackControls extends StatelessWidget {
  const PlaybackControls({
    required this.playing,
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.onShuffle,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onRepeat,
    this.large = false,
    super.key,
  });

  final bool large;
  final bool playing;
  final bool shuffleEnabled;
  final PlaybackRepeatMode repeatMode;
  final VoidCallback onShuffle;
  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;
  final VoidCallback onRepeat;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: large ? 340 : 220,
    height: large ? 68 : 44,
    child: FittedBox(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TransportButton(
            label: shuffleEnabled ? 'Shuffle on' : 'Shuffle off',
            hint: shuffleEnabled ? 'Turn shuffle off' : 'Turn shuffle on',
            active: shuffleEnabled,
            onPressed: onShuffle,
            icon: const Icon(Icons.sync_alt_rounded, size: 22),
          ),
          _TransportButton(
            label: 'Previous',
            onPressed: onPrevious,
            icon: const Icon(Icons.skip_previous, size: 26),
          ),
          _TransportButton(
            label: playing ? 'Pause' : 'Play',
            onPressed: onPlayPause,
            icon: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: onPlayPause == null
                    ? const Color(0xFF4A4D54)
                    : const Color(0xFFCCCFD4),
                shape: BoxShape.circle,
              ),
              child: GazeSwap(
                child: Icon(
                  key: ValueKey(playing),
                  playing ? Icons.pause : Icons.play_arrow,
                  size: 23,
                  color: onPlayPause == null
                      ? const Color(0xFF93969E)
                      : const Color(0xFF101217),
                ),
              ),
            ),
          ),
          _TransportButton(
            label: 'Next',
            onPressed: onNext,
            icon: const Icon(Icons.skip_next, size: 26),
          ),
          _TransportButton(
            label: switch (repeatMode) {
              PlaybackRepeatMode.off => 'Repeat off',
              PlaybackRepeatMode.all => 'Repeat queue',
              PlaybackRepeatMode.one => 'Repeat one',
            },
            hint: switch (repeatMode) {
              PlaybackRepeatMode.off => 'Repeat the queue',
              PlaybackRepeatMode.all => 'Repeat this song',
              PlaybackRepeatMode.one => 'Turn repeat off',
            },
            active: repeatMode != PlaybackRepeatMode.off,
            onPressed: onRepeat,
            icon: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(Icons.refresh_rounded, size: 24),
                GazeSwap(
                  child: repeatMode == PlaybackRepeatMode.one
                      ? const Text(
                          '1',
                          style: TextStyle(
                            color: Color(0xFFF4F4F5),
                            fontSize: 8,
                            height: 1,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.label,
    required this.onPressed,
    required this.icon,
    this.hint,
    this.active,
  });

  final String label;
  final String? hint;
  final bool? active;
  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    hint: hint,
    button: true,
    enabled: onPressed != null,
    toggled: active,
    onTap: onPressed,
    excludeSemantics: true,
    child: GazePress(
      enabled: onPressed != null,
      child: IconButton(
        onPressed: onPressed,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(Size(48, 48)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: const WidgetStatePropertyAll(CircleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return const Color(0xFF666972);
            }
            return const Color(0xFFF4F4F5);
          }),
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return Colors.white.withValues(alpha: .16);
            }
            if (states.contains(WidgetState.pressed)) {
              return Colors.white.withValues(alpha: .12);
            }
            if (states.contains(WidgetState.hovered)) {
              return Colors.white.withValues(alpha: .06);
            }
            return Colors.transparent;
          }),
        ),
        icon: SizedBox(
          width: 36,
          height: 36,
          child: Stack(
            alignment: Alignment.center,
            children: [
              icon,
              if (active != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: AnimatedSwitcher(
                    duration: GazeMotion.duration(context, GazeMotion.feedback),
                    reverseDuration: GazeMotion.duration(
                      context,
                      GazeMotion.feedback,
                    ),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: active == true
                        ? Icon(
                            key: const ValueKey('enabled'),
                            Icons.check_rounded,
                            size: 12,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : const SizedBox(
                            key: ValueKey('disabled'),
                            width: 12,
                            height: 12,
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
