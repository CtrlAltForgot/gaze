import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../design/gaze_theme.dart';
import '../design/gaze_motion.dart';
import '../jellyfin/jellyfin_connection_controller.dart';

class LibraryArtwork extends StatefulWidget {
  const LibraryArtwork({
    required this.connectionController,
    this.itemId,
    this.imageTag,
    this.bytes,
    this.dimension = 52,
    this.iconSize = 24,
    this.icon = Icons.music_note_rounded,
    super.key,
  });
  final JellyfinConnectionController connectionController;
  final String? itemId, imageTag;
  final Uint8List? bytes;
  final double dimension, iconSize;
  final IconData icon;
  @override
  State<LibraryArtwork> createState() => _LibraryArtworkState();
}

class _LibraryArtworkState extends State<LibraryArtwork> {
  ImageProvider? _image;
  StreamSubscription<JellyfinConnectionState>? _subscription;
  String? _account;
  bool _online = false;
  int _request = 0;
  Timer? _retry;
  bool _visible = true;
  int _misses = 0;
  bool _fromDisk = false;
  void _listen() {
    _account = widget.connectionController.accountKey;
    _online = widget.connectionController.state.isConnected;
    _subscription = widget.connectionController.states.listen((state) {
      final account = widget.connectionController.accountKey;
      if (account != _account || _online != state.isConnected) {
        final changed = account != _account;
        _account = account;
        _online = state.isConnected;
        if (mounted) {
          setState(() {
            if (changed) _image = null;
            _seed();
          });
          _load();
        }
      }
    });
  }

  void _seed() {
    if (widget.bytes != null) {
      _image = MemoryImage(widget.bytes!);
      _fromDisk = true;
      return;
    }
    final file = widget.connectionController.artworkFile(widget.itemId);
    if (file != null) {
      _image = FileImage(File(file));
      _fromDisk = true;
      return;
    }
    final bytes = widget.connectionController.peekArtwork(
      widget.itemId,
      widget.imageTag,
    );
    if (bytes != null) {
      _image = MemoryImage(bytes);
      _fromDisk = true;
    }
  }

  void _retryMissing() {
    _retry?.cancel();
    if (!mounted ||
        _image != null ||
        !widget.connectionController.state.isConnected ||
        widget.itemId == null)
      return;
    _retry = Timer(Duration(seconds: _misses < 2 ? 15 : 60), () {
      if (!mounted) return;
      if (_visible) {
        unawaited(_load());
      } else {
        _retryMissing();
      }
    });
  }

  Future<void> _load() async {
    _retry?.cancel();
    final request = ++_request;
    if (widget.bytes != null) return;
    final bytes = await widget.connectionController.loadArtwork(
      widget.itemId,
      widget.imageTag,
    );
    if (!mounted || request != _request) return;
    if (bytes == null) {
      _misses++;
      _retryMissing();
      return;
    }
    final file = widget.connectionController.artworkFile(widget.itemId);
    setState(() {
      _image = file == null ? MemoryImage(bytes) : FileImage(File(file));
    });
  }

  @override
  void initState() {
    super.initState();
    _seed();
    _listen();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LibraryArtwork old) {
    super.didUpdateWidget(old);
    final changed =
        old.connectionController != widget.connectionController ||
        old.itemId != widget.itemId ||
        (widget.itemId == null && !identical(old.bytes, widget.bytes));
    if (old.connectionController != widget.connectionController) {
      unawaited(_subscription?.cancel());
      _listen();
    }
    if (changed) {
      _image = null;
      _fromDisk = false;
      _misses = 0;
    }
    if (changed ||
        old.imageTag != widget.imageTag ||
        !identical(old.bytes, widget.bytes)) {
      _seed();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    ++_request;
    _retry?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _visible = TickerMode.valuesOf(context).enabled;
    return SizedBox.square(
      dimension: widget.dimension,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GazeRadii.control),
        child: ColoredBox(
          color: GazeColors.surfaceRaised,
          child: AnimatedSwitcher(
            duration: GazeMotion.duration(context),
            reverseDuration: GazeMotion.duration(context, GazeMotion.exit),
            child: _image == null
                ? Center(
                    key: const ValueKey('empty'),
                    child: Icon(
                      widget.icon,
                      size: widget.iconSize,
                      color: GazeColors.textSecondary,
                    ),
                  )
                : Image(
                    key: ValueKey(_image),
                    width: widget.dimension,
                    height: widget.dimension,
                    image: _image!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    frameBuilder: (context, child, frame, synchronous) =>
                        AnimatedOpacity(
                          opacity: _fromDisk || synchronous || frame != null
                              ? 1
                              : 0,
                          duration:
                              MediaQuery.disableAnimationsOf(context) ||
                                  _fromDisk
                              ? Duration.zero
                              : const Duration(milliseconds: 140),
                          child: child,
                        ),
                    errorBuilder: (_, _, _) => Center(
                      child: Icon(
                        widget.icon,
                        size: widget.iconSize,
                        color: GazeColors.textSecondary,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
