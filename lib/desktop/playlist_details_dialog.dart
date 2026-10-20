import '../design/gaze_motion.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_api.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import '../library/playlist_summary.dart';
import 'library_artwork.dart';

/// The original file is uploaded; the preview only crops it for display.
class PlaylistCoverSelection {
  const PlaylistCoverSelection(this.bytes);
  final Uint8List bytes;
}

Future<PlaylistSummary?> showPlaylistDetailsDialog(
  BuildContext context,
  JellyfinConnectionController controller,
  PlaylistSummary playlist, {
  ValueChanged<PlaylistSummary>? onSaved,
  Future<PlaylistCoverSelection?> Function()? chooseCover,
}) => showDialog<PlaylistSummary>(
  animationStyle: GazeMotion.style(context),
  context: context,
  barrierDismissible: false,
  builder: (_) => _PlaylistDetailsDialog(
    controller: controller,
    playlist: playlist,
    onSaved: onSaved,
    chooseCover: chooseCover,
  ),
);

class _PlaylistDetailsDialog extends StatefulWidget {
  const _PlaylistDetailsDialog({
    required this.controller,
    required this.playlist,
    this.onSaved,
    this.chooseCover,
  });
  final JellyfinConnectionController controller;
  final PlaylistSummary playlist;
  final ValueChanged<PlaylistSummary>? onSaved;
  final Future<PlaylistCoverSelection?> Function()? chooseCover;
  @override
  State<_PlaylistDetailsDialog> createState() => _PlaylistDetailsDialogState();
}

class _PlaylistDetailsDialogState extends State<_PlaylistDetailsDialog> {
  late final _name = TextEditingController(text: widget.playlist.title);
  late final _description = TextEditingController(
    text: widget.playlist.description,
  );
  late final _account = widget.controller.accountKey;
  late final _session = widget.controller.state.session;
  late PlaylistSummary _saved = widget.playlist;
  StreamSubscription<JellyfinConnectionState>? _connection;
  Uint8List? _image;
  String? _mimeType;
  String? _error;
  bool _busy = false;
  bool _choosing = false;
  bool _connectionChanged = false;
  bool get _sameAccount =>
      widget.controller.accountKey == _account &&
      identical(widget.controller.state.session, _session) &&
      widget.controller.state.isConnected;

  @override
  void initState() {
    super.initState();
    _connection = widget.controller.states.listen((_) {
      if (mounted && !_sameAccount) setState(() => _connectionChanged = true);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    unawaited(_connection?.cancel());
    super.dispose();
  }

  Future<PlaylistCoverSelection?> _pickFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose playlist image',
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    );
    if (result == null) return null;
    final picked = result.files.single;
    if (picked.size > 10 * 1024 * 1024)
      throw const FormatException('Choose an image smaller than 10 MB.');
    final bytes =
        picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null)
      throw const FormatException(
        'This image could not be opened. Try another file.',
      );
    return PlaylistCoverSelection(bytes);
  }

  Future<void> _chooseImage() async {
    if (_busy || _choosing || _connectionChanged) return;
    setState(() {
      _choosing = true;
      _error = null;
    });
    try {
      final selected = await (widget.chooseCover ?? _pickFile)();
      if (!mounted || selected == null || !_sameAccount) return;
      final bytes = selected.bytes;
      if (bytes.length > 10 * 1024 * 1024)
        throw const FormatException('Choose an image smaller than 10 MB.');
      final mime = _imageMimeType(bytes);
      if (mime == null)
        throw const FormatException('Choose a JPEG, PNG, or WebP image.');
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 600);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      if (!mounted || !_sameAccount) return;
      setState(() {
        _image = bytes;
        _mimeType = mime;
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'This image could not be opened. Try another file.',
        );
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _choosing) return;
    if (!_sameAccount) {
      setState(() => _connectionChanged = true);
      return;
    }
    final title = _name.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give your playlist a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.controller.updatePlaylistDetails(
        widget.playlist.id,
        name: title,
        description: _description.text.trim(),
        imageBytes: _image,
        imageMimeType: _mimeType,
      );
      if (!mounted) return;
      if (!_sameAccount) {
        setState(() => _connectionChanged = true);
        return;
      }
      widget.onSaved?.call(saved);
      Navigator.of(context).pop(saved);
    } on JellyfinPlaylistUpdateException catch (error) {
      if (!mounted || !_sameAccount) return;
      final saved = error.savedPlaylist;
      if (saved != null) {
        _saved = saved;
        widget.onSaved?.call(saved);
      }
      setState(() => _error = error.toString());
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_busy && !_choosing && !_connectionChanged;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Edit playlist'),
        content: SizedBox(
          width: 580,
          child: SingleChildScrollView(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 460;
                final cover = SizedBox(
                  width: narrow ? 144 : 184,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: 'Choose playlist image',
                        child: Semantics(
                          button: true,
                          label: 'Choose playlist image',
                          child: InkWell(
                            onTap: enabled ? _chooseImage : null,
                            borderRadius: BorderRadius.circular(
                              GazeRadii.control,
                            ),
                            child: Stack(
                              children: [
                                LibraryArtwork(
                                  connectionController: widget.controller,
                                  itemId: _saved.id,
                                  imageTag: _saved.imageTag,
                                  bytes: _image,
                                  dimension: narrow ? 144 : 184,
                                  icon: Icons.queue_music_rounded,
                                  iconSize: 56,
                                ),
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.7,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.edit_rounded,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: enabled ? _chooseImage : null,
                        child: Text(_choosing ? 'Opening…' : 'Choose image'),
                      ),
                      if (_image != null)
                        TextButton(
                          onPressed: enabled
                              ? () => setState(() {
                                  _image = null;
                                  _mimeType = null;
                                })
                              : null,
                          child: const Text('Undo image change'),
                        ),
                    ],
                  ),
                );
                final fields = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const ValueKey('playlist-name'),
                      controller: _name,
                      autofocus: true,
                      enabled: enabled,
                      maxLength: 140,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Playlist name',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('playlist-description'),
                      controller: _description,
                      enabled: enabled,
                      maxLength: 1000,
                      minLines: 3,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'What makes this playlist yours?',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (narrow) ...[
                      Center(child: cover),
                      const SizedBox(height: 16),
                      fields,
                    ] else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          cover,
                          const SizedBox(width: 24),
                          Expanded(child: fields),
                        ],
                      ),
                    const SizedBox(height: 12),
                    const Text(
                      'JPEG, PNG, or WebP · Up to 10 MB',
                      style: TextStyle(fontSize: 12),
                    ),
                    if (_connectionChanged || _error != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _connectionChanged
                              ? 'Your connection changed. Close this window and reconnect before saving.'
                              : _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: enabled ? _save : null,
            child: Text(_busy ? 'Saving…' : 'Save changes'),
          ),
        ],
      ),
    );
  }
}

String? _imageMimeType(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10)
    return 'image/png';
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255)
    return 'image/jpeg';
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP')
    return 'image/webp';
  return null;
}
