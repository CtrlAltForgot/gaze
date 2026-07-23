import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/library_search_results.dart';
import '../library/track_lyrics.dart';
import '../library/track_summary.dart';

class JellyfinServerAddress {
  JellyfinServerAddress._(this.uri);

  final Uri uri;

  factory JellyfinServerAddress.parse(String value) {
    final trimmed = value.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty) {
      throw const JellyfinConnectionException(
        'Enter a complete Jellyfin address beginning with http:// or https://.',
      );
    }
    if (parsed.userInfo.isNotEmpty) {
      throw const JellyfinConnectionException(
        'Do not include a username or password in the server address.',
      );
    }
    if (parsed.hasQuery || parsed.hasFragment) {
      throw const JellyfinConnectionException(
        'The Jellyfin server address cannot contain a query or fragment.',
      );
    }

    final normalizedPath = parsed.path == '/'
        ? ''
        : parsed.path.replaceFirst(RegExp(r'/+$'), '');
    return JellyfinServerAddress._(parsed.replace(path: normalizedPath));
  }

  bool get isEncrypted => uri.scheme == 'https';

  Uri endpoint(String path) {
    final endpointPath = path.startsWith('/') ? path : '/$path';
    return uri.replace(path: '${uri.path}$endpointPath');
  }

  @override
  String toString() => uri.toString();
}

class JellyfinClientIdentity {
  const JellyfinClientIdentity({
    required this.deviceId,
    this.clientName = 'gaze',
    this.deviceName = 'desktop',
    this.version = '0.1.0',
  });

  final String clientName;
  final String deviceName;
  final String deviceId;
  final String version;
}

class JellyfinServerInfo {
  const JellyfinServerInfo({
    required this.id,
    required this.name,
    required this.version,
  });

  final String id;
  final String name;
  final String version;
}

class JellyfinSession {
  const JellyfinSession({
    required this.accessToken,
    required this.userId,
    required this.userName,
  });

  final String accessToken;
  final String userId;
  final String userName;
}

class JellyfinAudioStreamSource {
  const JellyfinAudioStreamSource({required this.uri, required this.headers});

  final Uri uri;
  final Map<String, String> headers;
}

enum JellyfinPlaybackEvent { start, progress, stopped }

abstract interface class JellyfinApi {
  Future<JellyfinServerInfo> getPublicServerInfo(JellyfinServerAddress address);

  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  });

  Future<List<AlbumSummary>> getRecentlyAddedAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    int limit = 10,
  });

  Future<AlbumPage> getAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required AlbumSort sort,
    required int startIndex,
    required int limit,
  });

  Future<ArtistPage> getArtists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  });

  Future<List<AlbumSummary>> getArtistAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String artistId,
  });

  Future<List<TrackSummary>> getAlbumTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String albumId,
  });

  Future<LibrarySearchResults> searchLibrary({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String query,
    int limit = 24,
  });

  Future<TrackLyrics?> getLyrics({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String trackId,
  });

  Future<void> validateSession({
    required JellyfinServerAddress address,
    required JellyfinSession session,
  });

  JellyfinAudioStreamSource createDirectPlaySource({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
  });

  Future<void> reportPlayback({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required JellyfinPlaybackEvent event,
    required String itemId,
    required Duration position,
    required double volume,
    required bool paused,
  });

  void close();
}

class JellyfinConnectionException implements Exception {
  const JellyfinConnectionException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
