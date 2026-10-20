import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/library/artist_credits.dart';
import 'package:gaze/library/artist_summary.dart';
import 'package:gaze/library/artist_profile.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/library/track_summary.dart';

SongSummary song(String id, String artist, [String title = 'Song']) =>
    SongSummary(
      track: TrackSummary(
        id: id,
        title: title,
        artist: artist,
        duration: Duration.zero,
      ),
      album: 'Album',
    );
void main() {
  test('individual feature credits preserve legitimate band punctuation', () {
    expect(artistCredits('Lead; Guest; lead'), ['Lead', 'Guest']);
    expect(artistCredits('Lead feat. Guest'), ['Lead', 'Guest']);
    expect(artistCredits('Lead (feat. Guest)'), ['Lead', 'Guest']);
    for (final name in [
      'Earth, Wind & Fire',
      'AC/DC',
      'Florence + the Machine',
      'Simon & Garfunkel',
    ]) {
      expect(artistCredits(name), [name]);
    }
  });
  test(
    'catalogue merges combined artists and prefers an individual portrait',
    () {
      final catalog = artistCatalog(
        [
          const ArtistSummary(
            id: 'combined',
            name: r'$uicideboy$; Germ',
            imageTag: 'collage',
          ),
          const ArtistSummary(id: 'real', name: 'Germ', imageTag: 'portrait'),
          const ArtistSummary(id: 'other', name: r'$uicideboy$; Another guest'),
        ],
        songs: [song('new', 'New arrival; Germ')],
      );
      expect(catalog.length, 4);
      final germ = catalog.singleWhere((a) => a.name == 'Germ');
      expect(germ.artworkId, 'real');
      expect(germ.id, artistId('germ'));
      expect(
        catalog.singleWhere((a) => a.name == r'$uicideboy$').artworkId,
        isNull,
      );
      expect(catalog.map((a) => a.name), contains('New arrival'));
    },
  );
  test(
    'feature appearances match exact individual credits, not substrings',
    () {
      final songs = [
        song('a', 'Lead; Guest'),
        song('b', 'Guest'),
        song('c', 'Guesthouse'),
        song('a', 'Lead; Guest'),
      ];
      expect(songsForArtist('Guest', songs).map((s) => s.track.id), ['a', 'b']);
    },
  );
  test(
    'popularity is intersected with the library, leaving live editions distinct',
    () {
      const profile = ArtistProfile(
        musicBrainzId: 'artist',
        popularTitles: ['Unavailable', 'Hit', 'Hit', 'Deep cut'],
      );
      final ranked = popularLibrarySongs(profile, [
        song('1', 'Artist', 'Deep cut'),
        song('2', 'Artist', 'Hit (Live)'),
        song('3', 'Artist', 'Hit'),
      ]);
      expect(ranked.map((s) => s.track.id), ['3', '1']);
    },
  );
  test('age requires an exact birthday for a living person, never a band', () {
    final now = DateTime(2026, 10, 20);
    expect(
      const ArtistProfile(
        musicBrainzId: '1',
        type: 'Person',
        born: '2000-10-21',
      ).ageAt(now),
      25,
    );
    expect(
      const ArtistProfile(
        musicBrainzId: '1',
        type: 'Person',
        born: '2000-10-20',
      ).ageAt(now),
      26,
    );
    for (final p in [
      const ArtistProfile(musicBrainzId: '1', type: 'Person', born: '2000'),
      const ArtistProfile(
        musicBrainzId: '1',
        type: 'Group',
        born: '2000-01-01',
      ),
      const ArtistProfile(
        musicBrainzId: '1',
        type: 'Person',
        born: '2000-01-01',
        ended: true,
      ),
      const ArtistProfile(
        musicBrainzId: '1',
        type: 'Person',
        born: '2000-02-31',
      ),
    ]) {
      expect(p.ageAt(now), isNull);
    }
  });
}
