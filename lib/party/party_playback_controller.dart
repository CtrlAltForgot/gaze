import '../playback/playback_controller.dart';

/// Shared UI, keyboard and MPRIS commands obey the same host/follower boundary.
/// Party synchronization uses the wrapped controller directly.
class PartyPlaybackController implements PlaybackController {
  PartyPlaybackController(this.inner, this.isFollowing, {this.command});
  final PlaybackController inner;
  final Future<void> Function(String, Map<String, dynamic>)? command;
  final bool Function() isFollowing;
  @override
  PlaybackSnapshot get state => inner.state;
  @override
  Stream<PlaybackSnapshot> get states => inner.states;
  @override
  Future<void> loadLocalFile(String path) async {
    if (!isFollowing()) await inner.loadLocalFile(path);
  }

  @override
  Future<void> loadRemoteUrl(Uri url) async {
    if (!isFollowing()) await inner.loadRemoteUrl(url);
  }

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) async {
    if (!isFollowing()) await inner.loadRemoteSource(source);
  }

  @override
  Future<void> play() async {
    if (isFollowing()) {
      await command?.call('play', {});
    } else {
      await inner.play();
    }
  }

  @override
  Future<void> pause() async {
    if (isFollowing()) {
      await command?.call('pause', {});
    } else {
      await inner.pause();
    }
  }

  @override
  Future<void> stop() async {
    if (!isFollowing()) await inner.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (isFollowing()) {
      await command?.call('seek', {'positionMs': position.inMilliseconds});
    } else {
      await inner.seek(position);
    }
  }

  @override
  Future<void> setVolume(double volume) => inner.setVolume(volume);
  @override
  Future<void> dispose() => inner.dispose();
}
