import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'design/gaze_theme.dart';
import 'desktop/desktop_shell.dart';
import 'playback/media_kit_playback_controller.dart';
import 'playback/playback_controller.dart';
import 'playback/playback_test_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(GazeApp(controller: MediaKitPlaybackController()));
}

class GazeApp extends StatefulWidget {
  const GazeApp({required this.controller, super.key});

  final PlaybackController controller;

  @override
  State<GazeApp> createState() => _GazeAppState();
}

class _GazeAppState extends State<GazeApp> {
  bool _showPlaybackTest = false;

  @override
  void dispose() {
    unawaited(widget.controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'gaze',
      debugShowCheckedModeBanner: false,
      theme: buildGazeTheme(),
      home: _showPlaybackTest
          ? PlaybackTestScreen(
              controller: widget.controller,
              onClose: () => setState(() => _showPlaybackTest = false),
            )
          : DesktopShell(
              onOpenPlaybackTest: () =>
                  setState(() => _showPlaybackTest = true),
            ),
    );
  }
}
