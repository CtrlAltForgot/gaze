class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.title,
    this.trackCount,
    this.imageTag,
    this.description = '',
  });
  final String id;
  final String title;
  final int? trackCount;
  final String? imageTag;
  final String description;
}

class PlaylistPage {
  const PlaylistPage({
    required this.playlists,
    required this.totalCount,
    this.nextStartIndex,
  });
  final List<PlaylistSummary> playlists;
  final int totalCount;
  final int? nextStartIndex;
}
