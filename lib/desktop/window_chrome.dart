import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/gaze_theme.dart';

/// Other desktop runners retain their system frame until they implement this
/// capability. Linux uses GTK's native move/resize operations, including Wayland.
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({required this.child, super.key});
  final Widget child;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class WindowFrameScope extends InheritedWidget {
  const WindowFrameScope({
    required this.active,
    required super.child,
    super.key,
  });
  final bool active;
  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowFrameScope>()?.active ??
      false;
  @override
  bool updateShouldNotify(WindowFrameScope oldWidget) =>
      active != oldWidget.active;
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame> {
  static const _channel = MethodChannel('gaze/window_chrome');
  bool _ready = false;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'maximizedChanged' && mounted) {
        setState(() => _maximized = call.arguments == true);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _enable());
  }

  Future<void> _enable() async {
    try {
      final maximized = await _channel.invokeMethod<bool>('enableCustomFrame');
      if (mounted && maximized != null) {
        setState(() {
          _ready = true;
          _maximized = maximized;
        });
      }
    } on MissingPluginException {
      // An older runner retains the native title bar.
    } on PlatformException {
      // Leave native window controls available if negotiation fails.
    }
  }

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException catch (error) {
      debugPrint('gaze: window action unavailable (${error.code}).');
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(_ready && !_maximized ? 10 : 0),
      child: WindowFrameScope(
        active: _ready,
        child: Column(
          children: [
            if (_ready)
              Material(
                color: GazeColors.navigation,
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => unawaited(_invoke('beginDrag')),
                          onDoubleTap: () =>
                              unawaited(_invoke('toggleMaximize')),
                          child: const Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.only(left: 22),
                              child: Text(
                                'gaze',
                                style: TextStyle(
                                  color: GazeColors.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _control('Minimize', Icons.remove_rounded, 'minimize'),
                      _control(
                        _maximized ? 'Restore window' : 'Maximize',
                        _maximized
                            ? Icons.filter_none_rounded
                            : Icons.crop_square_rounded,
                        'toggleMaximize',
                      ),
                      _control(
                        'Close window',
                        Icons.close_rounded,
                        'close',
                        close: true,
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(child: widget.child),
          ],
        ),
      ),
    ),
  );

  Widget _control(
    String label,
    IconData icon,
    String method, {
    bool close = false,
  }) => Tooltip(
    message: label,
    child: SizedBox(
      width: 46,
      height: 36,
      child: IconButton(
        onPressed: () => unawaited(_invoke(method)),
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          foregroundColor: const WidgetStatePropertyAll(GazeColors.textPrimary),
          overlayColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? close
                      ? const Color(0xFFB53645)
                      : Colors.white12
                : null,
          ),
        ),
        icon: Icon(icon, size: 16, semanticLabel: label),
      ),
    ),
  );
}
