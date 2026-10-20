import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'desktop bridge keeps visibility and quitting as separate commands',
    () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('gaze/desktop_window');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const window = LinuxDesktopWindow();
      await window.setTrayAvailable(true);
      await window.show();
      await window.setTrayAvailable(false);
      expect(calls.map((c) => c.method), [
        'setTrayAvailable',
        'show',
        'setTrayAvailable',
      ]);
      expect(calls.first.arguments, true);
      expect(calls.last.arguments, false);
      await window.quit();
      expect(calls.last.method, 'quit');
    },
  );
}
