import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'playback_controller.dart';

class PlaybackTestScreen extends StatefulWidget {
  const PlaybackTestScreen({required this.controller, this.onClose, super.key});

  final PlaybackController controller;
  final VoidCallback? onClose;

  @override
  State<PlaybackTestScreen> createState() => _PlaybackTestScreenState();
}

class _PlaybackTestScreenState extends State<PlaybackTestScreen> {
  final TextEditingController _urlController = TextEditingController();
  String? _screenError;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _chooseLocalFile() async {
    setState(() => _screenError = null);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'aac',
          'flac',
          'm4a',
          'mp3',
          'ogg',
          'opus',
          'wav',
        ],
      );
      final path = result?.files.single.path;
      if (path != null) {
        await widget.controller.loadLocalFile(path);
      }
    } catch (error) {
      setState(() => _screenError = 'File picker error: $error');
    }
  }

  Future<void> _loadRemoteUrl() async {
    setState(() => _screenError = null);
    final url = Uri.tryParse(_urlController.text.trim());
    if (url == null) {
      setState(() => _screenError = 'Enter a valid audio URL.');
      return;
    }
    await widget.controller.loadRemoteUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.onClose == null
            ? null
            : IconButton(
                onPressed: widget.onClose,
                tooltip: 'Back to gaze',
                icon: const Icon(Icons.arrow_back_rounded),
              ),
        title: const Text('gaze playback technical test'),
      ),
      body: StreamBuilder<PlaybackSnapshot>(
        stream: widget.controller.states,
        initialData: widget.controller.state,
        builder: (context, snapshot) {
          final playback = snapshot.data ?? widget.controller.state;
          final durationMilliseconds = playback.duration.inMilliseconds;
          final maximumPosition = durationMilliseconds > 0
              ? durationMilliseconds.toDouble()
              : 1.0;
          final currentPosition = playback.position.inMilliseconds
              .clamp(0, maximumPosition.toInt())
              .toDouble();
          final error = _screenError ?? playback.errorMessage;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Disposable playback feasibility screen. '
                    'Do not enter private URLs or credentials.',
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: _chooseLocalFile,
                      child: const Text('Choose local audio file'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Remote HTTP or HTTPS audio URL',
                    ),
                    onSubmitted: (_) => _loadRemoteUrl(),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: _loadRemoteUrl,
                      child: const Text('Load remote URL'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: widget.controller.play,
                        child: const Text('Play'),
                      ),
                      FilledButton(
                        onPressed: widget.controller.pause,
                        child: const Text('Pause'),
                      ),
                      FilledButton(
                        onPressed: widget.controller.stop,
                        child: const Text('Stop'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('Source: ${playback.sourceLabel ?? 'none'}'),
                  Text('Playback state: ${playback.status.name}'),
                  Text(
                    'Completion: '
                    '${playback.completed ? 'reached' : 'not reached'}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Position: ${_formatDuration(playback.position)} / '
                    '${_formatDuration(playback.duration)}',
                  ),
                  Slider(
                    value: currentPosition,
                    max: maximumPosition,
                    label: _formatDuration(playback.position),
                    onChanged: durationMilliseconds > 0 ? (_) {} : null,
                    onChangeEnd: durationMilliseconds > 0
                        ? (value) => widget.controller.seek(
                            Duration(milliseconds: value.round()),
                          )
                        : null,
                  ),
                  Text('Volume: ${(playback.volume * 100).round()}%'),
                  Slider(
                    value: playback.volume.clamp(0.0, 1.0),
                    onChanged: widget.controller.setVolume,
                  ),
                  const SizedBox(height: 12),
                  const Text('Error output:'),
                  SelectableText(error ?? 'none'),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
