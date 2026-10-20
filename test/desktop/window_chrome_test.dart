import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/window_chrome.dart';

void main() {
  const channel = MethodChannel('gaze/window_chrome');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  testWidgets(
    'window controls wait for native support and keep close separate from quit',
    (tester) async {
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'enableCustomFrame' ? false : null;
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopWindowFrame(child: child!),
          home: const Scaffold(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(DesktopWindowFrame)).height, 600);
      expect(tester.getSize(find.byTooltip('Close window')).height, 36);
      for (final label in ['Minimize', 'Maximize', 'Close window']) {
        await tester.tap(find.byTooltip(label));
        await tester.pumpAndSettle();
      }
      expect(calls, [
        'enableCustomFrame',
        'minimize',
        'toggleMaximize',
        'close',
      ]);
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('maximizedChanged', true),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.byTooltip('Restore window'), findsOneWidget);
      await tester.drag(find.text('gaze'), const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(calls.last, 'beginDrag');
    },
  );

  testWidgets(
    'an unavailable native bridge retains the ordinary application layout',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopWindowFrame(child: Scaffold(body: Text('Library'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOneWidget);
      expect(find.byTooltip('Close window'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
