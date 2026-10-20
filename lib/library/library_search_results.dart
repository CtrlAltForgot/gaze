import 'dart:typed_data';

import 'album_summary.dart';
import 'track_summary.dart';

class LibrarySearchResults {
  const LibrarySearchResults({this.albums = const [], this.tracks = const []});

  final List<AlbumSummary> albums;
  final List<TrackSearchResult> tracks;

  bool get isEmpty => albums.isEmpty && tracks.isEmpty;
}

class TrackSearchResult {
  const TrackSearchResult({
    required this.track,
    this.artworkBytes,
    this.albumId,
    this.imageTag,
  });

  final TrackSummary track;
  final Uint8List? artworkBytes;
  final String? albumId;
  final String? imageTag;
}
