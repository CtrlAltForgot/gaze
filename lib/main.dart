import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'playback/media_kit_playback_controller.dart';
import 'playback/playback_controller.dart';
import 'playback/playback_test_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(GazeApp(controller: MediaKitPlaybackController()));
}

class GazeApp extends StatelessWidget {
  const GazeApp({required this.controller, super.key});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'gaze playback test',
      home: PlaybackTestScreen(controller: controller),
    );
  }
}
