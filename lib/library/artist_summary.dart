import 'dart:typed_data';

class ArtistSummary {
  const ArtistSummary({
    required this.id,
    required this.name,
    this.imageTag,
    this.artworkBytes,
  });

  final String id;
  final String name;
  final String? imageTag;
  final Uint8List? artworkBytes;
}

class ArtistPage {
  const ArtistPage({required this.artists, required this.totalCount});

  final List<ArtistSummary> artists;
  final int totalCount;
}
