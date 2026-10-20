import 'artist_summary.dart';
import 'song_summary.dart';

String artistKey(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String artistId(String name) =>
    'gaze-artist:${Uri.encodeComponent(artistKey(name))}';

/// Semicolons and explicit feature credits separate artists. Commas, ampersands,
/// slashes and plus signs can belong to a real group's name and stay intact.
List<String> artistCredits(String credit) {
  final seen = <String>{};
  final normalized = credit.replaceAllMapped(
    RegExp(
      r'\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+(.+?)[\)\]]\s*$',
      caseSensitive: false,
    ),
    (match) => '; ${match[1]}',
  );
  return normalized
      .split(
        RegExp(
          r'\s*;\s*|\s+(?:feat\.?|ft\.?|featuring)\s+',
          caseSensitive: false,
        ),
      )
      .map((name) => name.trim())
      .where(
        (name) =>
            name.isNotEmpty &&
            artistKey(name) != 'unknown artist' &&
            seen.add(artistKey(name)),
      )
      .toList(growable: false);
}

List<ArtistSummary> artistCatalog(
  Iterable<ArtistSummary> sources, {
  Iterable<SongSummary> songs = const [],
}) {
  final artists = <String, ArtistSummary>{};
  final native = <String>{};
  for (final source in sources) {
    final credits = artistCredits(source.name);
    for (final name in credits) {
      final key = artistKey(name);
      final individual = credits.length == 1;
      if (!artists.containsKey(key) || individual && !native.contains(key)) {
        artists[key] = ArtistSummary(
          id: artistId(name),
          name: name,
          artworkId: individual ? source.artworkId ?? source.id : null,
          imageTag: individual ? source.imageTag : null,
          artworkBytes: individual ? source.artworkBytes : null,
        );
      }
      if (individual) native.add(key);
    }
  }
  for (final song in songs) {
    for (final name in artistCredits(song.track.artist)) {
      artists.putIfAbsent(
        artistKey(name),
        () => ArtistSummary(id: artistId(name), name: name),
      );
    }
  }
  return artists.values.toList()
    ..sort((a, b) => artistKey(a.name).compareTo(artistKey(b.name)));
}

List<SongSummary> songsForArtist(String artist, Iterable<SongSummary> songs) {
  final key = artistKey(artist);
  final seen = <String>{};
  return songs
      .where(
        (song) =>
            artistCredits(
              song.track.artist,
            ).any((name) => artistKey(name) == key) &&
            seen.add(song.track.id),
      )
      .toList();
}
