import 'dart:typed_data';

class AlbumSummary {
  const AlbumSummary({
    required this.id,
    required this.title,
    required this.artist,
    this.year,
    this.artworkBytes,
  });

  final String id;
  final String title;
  final String artist;
  final int? year;
  final Uint8List? artworkBytes;
}

enum AlbumSort { recentlyAdded, title, artist, releaseYear }

class AlbumPage {
  const AlbumPage({required this.albums, required this.totalCount});

  final List<AlbumSummary> albums;
  final int totalCount;
}
