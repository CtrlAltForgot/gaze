import 'dart:convert';
import 'package:http/http.dart' as http;
import '../library/track_lyrics.dart';
import '../library/artist_credits.dart';
import '../storage/local_content_cache.dart';
import 'lyrics_provider.dart';

class LrclibLyricsProvider implements LyricsProvider {
  LrclibLyricsProvider(this._client, {required this.cache});
  final http.Client _client;
  final LocalContentCache cache;
  final Map<String, Future<TrackLyrics?>> _pending = {};

  @override
  Future<TrackLyrics?> find({
    required String title,
    required String artist,
    required Duration duration,
  }) {
    if (title.trim().isEmpty || artist.trim().isEmpty) return Future.value();
    final key =
        'lyrics-v2:${jsonEncode([title.trim().toLowerCase(), artist.trim().toLowerCase(), duration.inSeconds])}';
    return _pending.putIfAbsent(
      key,
      () => _load(key, title, artist, duration).whenComplete(() {
        _pending.remove(key);
      }),
    );
  }

  Future<TrackLyrics?> _load(
    String key,
    String title,
    String artist,
    Duration duration,
  ) async {
    try {
      final saved = await cache.read(key);
      if (saved != null)
        return _parse(jsonDecode(saved) as Map<String, dynamic>);
    } catch (_) {
      /* A damaged cache must not prevent a fresh lookup. */
    }
    // Prefer exact recording matches. Search is only a fallback, and never
    // accepts a different title, artist or duration just to obtain timestamps.
    final names = {artist.trim(), ...artistCredits(artist).take(1)};
    Map<String, dynamic>? fallback;
    Object? failure;
    for (final name in names) {
      try {
        final data = await _request('/api/get', {
          'track_name': title.trim(),
          'artist_name': name,
          if (duration > Duration.zero)
            'duration': '${duration.inMilliseconds / 1000}',
        });
        if (data is! Map<String, dynamic>) continue;
        final recordingDuration = data['duration'];
        if (recordingDuration is num &&
            duration > Duration.zero &&
            (recordingDuration - duration.inMilliseconds / 1000).abs() > 2)
          continue;
        final parsed = _parse(data);
        if (parsed?.hasTiming == true) return _save(key, data);
        if (parsed != null) fallback ??= data;
      } catch (error) {
        failure = error;
      }
    }
    if (duration > Duration.zero) {
      try {
        final results = await _request('/api/search', {
          'track_name': title.trim(),
          'artist_name': names.last,
        });
        if (results is List) {
          final matches = results.whereType<Map<String, dynamic>>().where((
            data,
          ) {
            final seconds = data['duration'];
            return seconds is num &&
                (seconds - duration.inMilliseconds / 1000).abs() <= 2 &&
                _normalized(data['trackName']) == _normalized(title) &&
                names.any(
                  (name) =>
                      _normalized(name) == _normalized(data['artistName']),
                ) &&
                _parse(data)?.hasTiming == true;
          }).toList();
          matches.sort(
            (a, b) => ((a['duration'] as num) - duration.inMilliseconds / 1000)
                .abs()
                .compareTo(
                  ((b['duration'] as num) - duration.inMilliseconds / 1000)
                      .abs(),
                ),
          );
          if (matches.isNotEmpty) return _save(key, matches.first);
        }
      } catch (error) {
        failure = error;
      }
    }
    if (fallback != null) return _save(key, fallback);
    if (failure != null) throw failure;
    return _save(key, {});
  }

  String _normalized(Object? text) => text is String
      ? text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')
      : '';

  Future<Object?> _request(String path, Map<String, String> parameters) async {
    final response = await _client
        .get(
          Uri.https('lrclib.net', path, parameters),
          headers: {
            'User-Agent': 'gaze/0.1 (desktop music player)',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200)
      throw StateError('Lyrics provider is temporarily unavailable.');
    if (response.bodyBytes.length > 1024 * 1024)
      throw StateError('Lyrics response is too large.');
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<TrackLyrics?> _save(String key, Map<String, dynamic> data) async {
    final lyrics = _parse(data);
    try {
      await cache.write(
        key,
        jsonEncode(data),
        ttl: lyrics?.hasTiming == true
            ? const Duration(days: 30)
            : const Duration(hours: 6),
      );
    } catch (_) {}
    return lyrics;
  }

  TrackLyrics? _parse(Map<String, dynamic> data) {
    final timed = data['syncedLyrics'];
    if (timed is String && timed.trim().isNotEmpty) {
      final lines = parseLrc(timed);
      if (lines.isNotEmpty)
        return TrackLyrics(
          lines: lines,
          isSynchronized: true,
          source: 'LRCLIB',
        );
    }
    final plain = data['plainLyrics'];
    if (plain is String && plain.trim().isNotEmpty)
      return TrackLyrics(
        lines: plain.split('\n').map((line) => LyricLine(text: line)).toList(),
        isSynchronized: false,
        source: 'LRCLIB',
      );
    return null;
  }
}

List<LyricLine> parseLrc(String lrc) {
  final result = <LyricLine>[];
  final stamp = RegExp(r'\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]');
  final offset = RegExp(
    r'\[offset:([+-]?\d+)\]',
    caseSensitive: false,
  ).firstMatch(lrc);
  final shift = int.tryParse(offset?.group(1) ?? '') ?? 0;
  for (final line in lrc.split('\n')) {
    final matches = stamp.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final text = line.substring(matches.last.end).trim();
    for (final match in matches) {
      if (int.parse(match[2]!) >= 60) continue;
      final ms =
          int.parse(match[1]!) * 60000 +
          int.parse(match[2]!) * 1000 +
          int.parse((match[3] ?? '0').padRight(3, '0')) +
          shift;
      result.add(
        LyricLine(
          text: text,
          start: Duration(milliseconds: ms.clamp(0, 86400000)),
        ),
      );
    }
  }
  result.sort((a, b) => a.start!.compareTo(b.start!));
  return result;
}
