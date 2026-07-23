import 'dart:typed_data';

import 'track_summary.dart';

class SongSummary {
  const SongSummary({
    required this.track,
    required this.album,
    this.artworkBytes,
  });

  final TrackSummary track;
  final String album;
  final Uint8List? artworkBytes;
}

class SongPage {
  const SongPage({required this.songs, required this.totalCount});

  final List<SongSummary> songs;
  final int totalCount;
}
