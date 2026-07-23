class TrackLyrics {
  const TrackLyrics({required this.lines, required this.isSynchronized});

  final List<LyricLine> lines;
  final bool isSynchronized;
}

class LyricLine {
  const LyricLine({required this.text, this.start});

  final String text;
  final Duration? start;
}
