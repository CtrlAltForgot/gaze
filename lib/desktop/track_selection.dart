import '../design/gaze_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

/// A list owns selection, independently of playback and keyboard focus.
class TrackSelectionScope extends StatefulWidget {
  const TrackSelectionScope({required this.child, super.key});
  final Widget child;

  @override
  State<TrackSelectionScope> createState() => _TrackSelectionScopeState();
}

class _TrackSelectionScopeState extends State<TrackSelectionScope> {
  final selection = ValueNotifier<Object?>(null);
  @override
  void dispose() {
    selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _Selection(notifier: selection, child: widget.child);
}

class _Selection extends InheritedNotifier<ValueNotifier<Object?>> {
  const _Selection({required super.notifier, required super.child});
}

class SelectableTrack extends StatefulWidget {
  const SelectableTrack({
    required this.identity,
    required this.builder,
    this.onPlay,
    this.onContextMenu,
    super.key,
  });
  final Object identity;
  final Widget Function(BuildContext context, bool active) builder;
  final VoidCallback? onPlay;
  final ValueChanged<Offset>? onContextMenu;

  @override
  State<SelectableTrack> createState() => _SelectableTrackState();
}

class _SelectableTrackState extends State<SelectableTrack> {
  final _focus = FocusNode();
  bool _hovered = false;
  bool _focused = false;
  bool _localSelected = false;
  ValueNotifier<Object?>? get _selection =>
      context.dependOnInheritedWidgetOfExactType<_Selection>()?.notifier;

  void _select() {
    _focus.requestFocus();
    final selection = _selection;
    if (selection != null) {
      selection.value = widget.identity;
    } else {
      setState(() => _localSelected = true);
    }
  }

  void _menu(Offset position) {
    _select();
    widget.onContextMenu?.call(position);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    final selected = selection == null
        ? _localSelected
        : selection.value == widget.identity;
    return Semantics(
      selected: selected,
      onTap: _select,
      customSemanticsActions: widget.onPlay == null
          ? null
          : {const CustomSemanticsAction(label: 'Play'): widget.onPlay!},
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter) {
            widget.onPlay?.call();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.contextMenu ||
              (event.logicalKey == LogicalKeyboardKey.f10 &&
                  HardwareKeyboard.instance.isShiftPressed)) {
            final box = context.findRenderObject()! as RenderBox;
            _menu(box.localToGlobal(Offset(48, box.size.height)));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons == kPrimaryMouseButton) _select();
          },
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Material(
              animationDuration: GazeMotion.duration(
                context,
                GazeMotion.feedback,
              ),
              color: Colors.white.withValues(
                alpha: selected
                    ? .12
                    : _hovered
                    ? .055
                    : 0,
              ),
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                focusNode: _focus,
                onFocusChange: (value) => setState(() => _focused = value),
                borderRadius: BorderRadius.circular(6),
                onTapDown: (_) => _select(),
                onTap: _select,
                onDoubleTap: widget.onPlay,
                onSecondaryTapDown: widget.onContextMenu == null
                    ? null
                    : (details) => _menu(details.globalPosition),
                onLongPress: widget.onContextMenu == null
                    ? null
                    : () {
                        final box = context.findRenderObject()! as RenderBox;
                        _menu(box.localToGlobal(Offset(48, box.size.height)));
                      },
                child: widget.builder(
                  context,
                  selected || _hovered || _focused,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
