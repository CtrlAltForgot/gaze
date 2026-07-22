import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_test_screen.dart';

void main() {
  testWidgets('shows all playback spike controls and status', (tester) async {
    final controller = FakePlaybackController();

    await tester.pumpWidget(
      MaterialApp(home: PlaybackTestScreen(controller: controller)),
    );

    expect(find.text('gaze playback technical test'), findsOneWidget);
    expect(find.text('Choose local audio file'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Load remote URL'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Playback state: idle'), findsOneWidget);
    expect(find.text('Completion: not reached'), findsOneWidget);
    expect(find.text('Error output:'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://example.com/audio.flac',
    );
    await tester.tap(find.text('Load remote URL'));
    await tester.pump();

    expect(controller.loadedRemoteUrl.toString(), endsWith('audio.flac'));
    expect(find.textContaining('Source: https://example.com'), findsOneWidget);
  });
}

class FakePlaybackController implements PlaybackController {
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot _state = const PlaybackSnapshot();
  Uri? loadedRemoteUrl;

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  Future<void> loadLocalFile(String path) async {}

  @override
  Future<void> loadRemoteUrl(Uri url) async {
    loadedRemoteUrl = url;
    _state = _state.copyWith(
      status: PlaybackStatus.ready,
      sourceLabel: url.toString(),
    );
    _states.add(_state);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _states.close();
}
