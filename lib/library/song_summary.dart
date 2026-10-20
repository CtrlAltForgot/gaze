import 'dart:typed_data';

import 'track_summary.dart';

class SongSummary {
  const SongSummary({
    required this.track,
    required this.album,
    this.albumId,
    this.entryId,
    this.imageTag,
    this.artworkBytes,
  });

  final TrackSummary track;
  final String album;
  final String? albumId;
  final String? entryId;
  final String? imageTag;
  final Uint8List? artworkBytes;
}

class SongPage {
  const SongPage({
    required this.songs,
    required this.totalCount,
    this.nextStartIndex,
    this.fromCache = false,
  });

  final List<SongSummary> songs;
  final int totalCount;
  final int? nextStartIndex;
  final bool fromCache;
}
