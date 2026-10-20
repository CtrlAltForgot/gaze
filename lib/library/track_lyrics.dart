class TrackLyrics {
  const TrackLyrics({
    required this.lines,
    required this.isSynchronized,
    this.source = 'Library',
  });

  final List<LyricLine> lines;
  final bool isSynchronized;
  final String source;

  bool get hasTiming =>
      isSynchronized && lines.any((line) => line.start != null);

  /// Uses actual timestamps, including after backward seeks. Untimed headers
  /// and gaps must not stop a synchronized timeline from advancing.
  int lineAt(Duration position) {
    if (!hasTiming) return -1;
    // Native audio positions may round a seek down by a fraction of a
    // millisecond. Keep the clicked line active even while playback is paused.
    final boundary = position + const Duration(milliseconds: 1);
    var active = -1;
    Duration? latest;
    for (var index = 0; index < lines.length; index++) {
      final start = lines[index].start;
      if (start != null &&
          start <= boundary &&
          (latest == null || start >= latest)) {
        active = index;
        latest = start;
      }
    }
    return active;
  }
}

class LyricLine {
  const LyricLine({required this.text, this.start});

  final String text;
  final Duration? start;
}
