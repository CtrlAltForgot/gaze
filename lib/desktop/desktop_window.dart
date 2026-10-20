import 'package:flutter/services.dart';

/// Window operations stay in the desktop layer; playback never owns a window.
abstract interface class DesktopWindow {
  Future<void> show();
  Future<void> setTrayAvailable(bool available);
  Future<void> quit();
}

/// The Linux runner preserves its Flutter view when the title-bar X is pressed.
class LinuxDesktopWindow implements DesktopWindow {
  const LinuxDesktopWindow();

  static const _channel = MethodChannel('gaze/desktop_window');

  void setQuitHandler(Future<void> Function()? onQuit) {
    _channel.setMethodCallHandler(
      onQuit == null
          ? null
          : (call) async {
              if (call.method == 'quitRequested') await onQuit();
            },
    );
  }

  @override
  Future<void> show() => _channel.invokeMethod<void>('show');

  @override
  Future<void> setTrayAvailable(bool available) =>
      _channel.invokeMethod<void>('setTrayAvailable', available);

  @override
  Future<void> quit() => _channel.invokeMethod<void>('quit');
}
