import '../library/track_lyrics.dart';

abstract interface class LyricsProvider {
  Future<TrackLyrics?> find({
    required String title,
    required String artist,
    required Duration duration,
  });
}
