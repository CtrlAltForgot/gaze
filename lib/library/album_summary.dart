import 'dart:typed_data';

class AlbumSummary {
  const AlbumSummary({
    required this.id,
    required this.title,
    required this.artist,
    this.artworkBytes,
  });

  final String id;
  final String title;
  final String artist;
  final Uint8List? artworkBytes;
}
