import 'package:flutter/material.dart';

void main() {
  runApp(const GazeApp());
}

class GazeApp extends StatelessWidget {
  const GazeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'gaze',
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('gaze'),
              SizedBox(height: 12),
              Text('The desktop shell is running.'),
            ],
          ),
        ),
      ),
    );
  }
}
