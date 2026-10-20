import 'dart:convert';
import '../library/song_summary.dart';
import '../library/track_summary.dart';

String encodePlaylistSnapshot(SongPage page) => jsonEncode({
  'total': page.totalCount,
  'songs': page.songs
      .map(
        (s) => {
          'id': s.track.id,
          'title': s.track.title,
          'artist': s.track.artist,
          'ms': s.track.duration.inMilliseconds,
          'track': s.track.trackNumber,
          'disc': s.track.discNumber,
          'album': s.album,
          'albumId': s.albumId,
          'imageTag': s.imageTag,
          'entryId': s.entryId,
        },
      )
      .toList(),
});
SongPage decodePlaylistSnapshot(String value) {
  final data = jsonDecode(value) as Map<String, dynamic>;
  final songs = (data['songs'] as List)
      .map(
        (v) => SongSummary(
          track: TrackSummary(
            id: v['id'] as String,
            title: v['title'] as String,
            artist: v['artist'] as String,
            duration: Duration(milliseconds: v['ms'] as int),
            trackNumber: v['track'] as int?,
            discNumber: v['disc'] as int?,
          ),
          album: v['album'] as String,
          albumId: v['albumId'] as String?,
          imageTag: v['imageTag'] as String?,
          entryId: v['entryId'] as String?,
        ),
      )
      .toList();
  if (songs.length != data['total'])
    throw const FormatException('Incomplete cached playlist');
  return SongPage(songs: songs, totalCount: songs.length, fromCache: true);
}
