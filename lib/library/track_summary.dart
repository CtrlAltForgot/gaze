class TrackSummary {
  const TrackSummary({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    this.trackNumber,
    this.discNumber,
  });

  final String id;
  final String title;
  final String artist;
  final Duration duration;
  final int? trackNumber;
  final int? discNumber;
}
