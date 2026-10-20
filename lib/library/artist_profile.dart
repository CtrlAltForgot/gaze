import 'song_summary.dart';

class ArtistProfile {
  const ArtistProfile({
    required this.musicBrainzId,
    this.origin,
    this.type,
    this.born,
    this.ended = false,
    this.biography,
    this.wikipediaUrl,
    this.photoUrl,
    this.photoCredit,
    this.photoSource,
    this.popularTitles = const [],
  });
  final String musicBrainzId;
  final String? origin,
      type,
      born,
      biography,
      wikipediaUrl,
      photoUrl,
      photoCredit,
      photoSource;
  final bool ended;
  final List<String> popularTitles;

  int? ageAt(DateTime now) {
    if (type != 'Person' ||
        ended ||
        born == null ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(born!))
      return null;
    final date = DateTime.tryParse(born!);
    if (date == null ||
        date.toIso8601String().substring(0, 10) != born ||
        date.isAfter(now))
      return null;
    final age =
        now.year -
        date.year -
        (now.month < date.month || now.month == date.month && now.day < date.day
            ? 1
            : 0);
    return age >= 0 && age < 120 ? age : null;
  }

  Map<String, dynamic> toJson() => {
    'id': musicBrainzId,
    'origin': origin,
    'type': type,
    'born': born,
    'ended': ended,
    'bio': biography,
    'wiki': wikipediaUrl,
    'photo': photoUrl,
    'photoCredit': photoCredit,
    'photoSource': photoSource,
    'popular': popularTitles,
  };
  factory ArtistProfile.fromJson(Map<String, dynamic> json) => ArtistProfile(
    musicBrainzId: json['id'] as String,
    origin: json['origin'] as String?,
    type: json['type'] as String?,
    born: json['born'] as String?,
    ended: json['ended'] == true,
    biography: json['bio'] as String?,
    wikipediaUrl: json['wiki'] as String?,
    photoUrl: json['photo'] as String?,
    photoCredit: json['photoCredit'] as String?,
    photoSource: json['photoSource'] as String?,
    popularTitles: (json['popular'] as List? ?? []).cast<String>(),
  );
}

String recordingKey(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'[’‘]'), "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Keep editions distinct (live/remix/remaster). Never recommend unavailable audio.
List<SongSummary> popularLibrarySongs(
  ArtistProfile profile,
  List<SongSummary> songs,
) {
  final byTitle = <String, SongSummary>{};
  for (final song in songs) {
    byTitle.putIfAbsent(recordingKey(song.track.title), () => song);
  }
  final seen = <String>{};
  return [
    for (final title in profile.popularTitles)
      if (byTitle.containsKey(recordingKey(title)) &&
          seen.add(recordingKey(title)))
        byTitle[recordingKey(title)]!,
  ];
}
