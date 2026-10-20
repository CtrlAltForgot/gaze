import 'dart:async';

import 'package:dbus/dbus.dart';

import '../playback/playback_controller.dart';
import '../playback/playback_queue_controller.dart';

/// Linux's background media keys and desktop player use this MPRIS adapter.
/// It only submits commands to the same controllers used by the gaze UI.
class LinuxMediaSession extends DBusObject {
  LinuxMediaSession({
    required PlaybackController playback,
    required PlaybackQueueController queue,
    required DBusClient bus,
    this.busName = 'org.mpris.MediaPlayer2.gaze',
  }) : _playback = playback,
       _queue = queue,
       _bus = bus,
       super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  static const rootInterface = 'org.mpris.MediaPlayer2';
  static const playerInterface = '$rootInterface.Player';
  final PlaybackController _playback;
  final PlaybackQueueController _queue;
  final DBusClient _bus;
  final String busName;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Map<String, DBusValue> _published = {};
  bool _disposed = false;
  Future<void>? _starting;
  Future<void> _commands = Future.value();
  Future<void> _signals = Future.value();
  int _trackNumber = 0;
  String? _sourceIdentity;
  int _previousPosition = 0;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (_disposed) return;
    try {
      await _bus.registerObject(this);
      if (_disposed) return;
      final reply = await _bus.requestName(
        busName,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (reply != DBusRequestNameReply.primaryOwner &&
          reply != DBusRequestNameReply.alreadyOwner) {
        throw StateError('Another gaze instance owns the media session.');
      }
      if (_disposed) return;
      _published = _playerProperties;
      _previousPosition = _playback.state.position.inMicroseconds;
      _subscriptions.add(_playback.states.listen((_) => _publish()));
      _subscriptions.add(_queue.states.listen((_) => _publish()));
    } catch (_) {
      await _bus.close();
      rethrow;
    }
  }

  bool get _hasTrack => _playback.state.sourceLabel != null;
  bool get _playing =>
      _playback.state.status == PlaybackStatus.playing ||
      _playback.state.status == PlaybackStatus.buffering;
  bool get _canPlay =>
      _hasTrack &&
      _playback.state.status != PlaybackStatus.loading &&
      _playback.state.status != PlaybackStatus.error;
  bool get _canSeek => _canPlay && _playback.state.duration > Duration.zero;

  String get _trackId {
    // Never put an authenticated source URL or server address on the bus.
    // A serial also distinguishes identical songs in separate queue slots.
    final identity = _hasTrack
        ? '${_playback.state.itemId}|${_playback.state.sourceLabel}|${_queue.state.currentIndex}'
        : null;
    if (identity != _sourceIdentity) {
      _sourceIdentity = identity;
      _trackNumber++;
    }
    return _hasTrack
        ? '/org/mpris/MediaPlayer2/track/$_trackNumber'
        : '/org/mpris/MediaPlayer2/TrackList/NoTrack';
  }

  Map<String, DBusValue> get _rootProperties => {
    'CanQuit': const DBusBoolean(false),
    'CanRaise': const DBusBoolean(false),
    'HasTrackList': const DBusBoolean(false),
    'Identity': const DBusString('gaze'),
    'DesktopEntry': const DBusString('com.example.gaze'),
    'SupportedUriSchemes': DBusArray.string([]),
    'SupportedMimeTypes': DBusArray.string([]),
  };

  Map<String, DBusValue> get _playerProperties => {
    'PlaybackStatus': DBusString(
      _playing
          ? 'Playing'
          : switch (_playback.state.status) {
              PlaybackStatus.ready || PlaybackStatus.paused => 'Paused',
              _ => 'Stopped',
            },
    ),
    'Shuffle': DBusBoolean(_queue.state.shuffleEnabled),
    'LoopStatus': DBusString(switch (_queue.state.repeatMode) {
      PlaybackRepeatMode.off => 'None',
      PlaybackRepeatMode.all => 'Playlist',
      PlaybackRepeatMode.one => 'Track',
    }),
    'Rate': const DBusDouble(1),
    'Metadata': DBusDict.stringVariant({
      if (_hasTrack) ...{
        'mpris:trackid': DBusObjectPath(_trackId),
        'mpris:length': DBusInt64(_playback.state.duration.inMicroseconds),
        // A raw-URL diagnostic source has no safe public title.
        'xesam:title': DBusString(_safeTitle),
        'xesam:artist': DBusArray.string([_playback.state.artist ?? '']),
      },
    }),
    'Volume': DBusDouble(_playback.state.volume),
    'Position': DBusInt64(_playback.state.position.inMicroseconds),
    'MinimumRate': const DBusDouble(1),
    'MaximumRate': const DBusDouble(1),
    'CanGoNext': DBusBoolean(_queue.state.hasNext),
    'CanGoPrevious': DBusBoolean(
      _queue.state.hasPrevious ||
          (_canSeek &&
              _playback.state.position >
                  PlaybackQueueController.previousRestartThreshold),
    ),
    'CanPlay': DBusBoolean(_canPlay),
    'CanPause': DBusBoolean(_canPlay),
    'CanSeek': DBusBoolean(_canSeek),
    'CanControl': const DBusBoolean(true),
  };

  String get _safeTitle {
    final title = _playback.state.title;
    if (title == null ||
        title.startsWith('http://') ||
        title.startsWith('https://')) {
      return 'gaze';
    }
    return title;
  }

  void _publish() {
    if (_disposed) return;
    final current = _playerProperties;
    final changed = <String, DBusValue>{
      for (final entry in current.entries)
        if (entry.key != 'Position' && _published[entry.key] != entry.value)
          entry.key: entry.value,
    };
    final position = _playback.state.position.inMicroseconds;
    final jumped = (position - _previousPosition).abs() > 2000000;
    _previousPosition = position;
    _published = current;
    _signals = _signals
        .then((_) async {
          if (_disposed) return;
          if (changed.isNotEmpty) {
            await emitPropertiesChanged(
              playerInterface,
              changedProperties: changed,
            );
          }
          if (jumped && !changed.containsKey('Metadata')) {
            await emitSignal(playerInterface, 'Seeked', [DBusInt64(position)]);
          }
        })
        .catchError((Object _) {
          // A disappearing desktop bus must not interrupt music playback.
        });
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      rootInterface,
      methods: [DBusIntrospectMethod('Raise'), DBusIntrospectMethod('Quit')],
      properties: _introspectProperties(_rootProperties),
    ),
    DBusIntrospectInterface(
      playerInterface,
      methods: [
        for (final name in [
          'Play',
          'Pause',
          'PlayPause',
          'Stop',
          'Next',
          'Previous',
        ])
          DBusIntrospectMethod(name),
        DBusIntrospectMethod('Seek', args: [_argument('Offset', 'x')]),
        DBusIntrospectMethod(
          'SetPosition',
          args: [_argument('TrackId', 'o'), _argument('Position', 'x')],
        ),
      ],
      signals: [
        DBusIntrospectSignal(
          'Seeked',
          args: [
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.out,
              name: 'Position',
            ),
          ],
        ),
      ],
      properties: _introspectProperties(_playerProperties),
    ),
  ];

  DBusIntrospectArgument _argument(String name, String signature) =>
      DBusIntrospectArgument(
        DBusSignature(signature),
        DBusArgumentDirection.in_,
        name: name,
      );

  List<DBusIntrospectProperty> _introspectProperties(
    Map<String, DBusValue> values,
  ) => [
    for (final entry in values.entries)
      DBusIntrospectProperty(
        entry.key,
        entry.value.signature,
        access:
            const {
              'Volume',
              'Rate',
              'Shuffle',
              'LoopStatus',
            }.contains(entry.key)
            ? DBusPropertyAccess.readwrite
            : DBusPropertyAccess.read,
      ),
  ];

  Map<String, DBusValue>? _properties(String interface) => switch (interface) {
    rootInterface => _rootProperties,
    playerInterface => _playerProperties,
    _ => null,
  };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final properties = _properties(interface);
    if (properties == null) return DBusMethodErrorResponse.unknownInterface();
    final value = properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    final properties = _properties(interface);
    return properties == null
        ? DBusMethodErrorResponse.unknownInterface()
        : DBusGetAllPropertiesResponse(properties);
  }

  // Serialize rapid button presses so two asynchronous track loads cannot race.
  Future<DBusMethodResponse> _command(Future<void> Function() action) {
    final result = _commands.then<DBusMethodResponse>((_) async {
      if (_disposed) return DBusMethodErrorResponse.failed();
      try {
        await action();
        return DBusMethodSuccessResponse();
      } catch (_) {
        return DBusMethodErrorResponse.failed('Playback command failed.');
      }
    });
    _commands = result.then((_) {});
    return result;
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    final properties = _properties(interface);
    if (properties == null) return DBusMethodErrorResponse.unknownInterface();
    if (!properties.containsKey(name))
      return DBusMethodErrorResponse.unknownProperty();
    if (interface != playerInterface ||
        !const {'Volume', 'Rate', 'Shuffle', 'LoopStatus'}.contains(name)) {
      return DBusMethodErrorResponse.propertyReadOnly();
    }
    if (name == 'Shuffle') {
      if (value is! DBusBoolean) return DBusMethodErrorResponse.invalidArgs();
      return _command(() async => _queue.setShuffle(value.value));
    }
    if (name == 'LoopStatus') {
      if (value is! DBusString) return DBusMethodErrorResponse.invalidArgs();
      final mode = switch (value.value) {
        'None' => PlaybackRepeatMode.off,
        'Playlist' => PlaybackRepeatMode.all,
        'Track' => PlaybackRepeatMode.one,
        _ => null,
      };
      if (mode == null) return DBusMethodErrorResponse.invalidArgs();
      return _command(() async => _queue.setRepeatMode(mode));
    }
    if (value is! DBusDouble || !value.value.isFinite)
      return DBusMethodErrorResponse.invalidArgs();
    return _command(() async {
      if (name == 'Volume') await _playback.setVolume(value.value.clamp(0, 1));
      if (name == 'Rate' && value.value == 0 && _canPlay)
        await _playback.pause();
    });
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == rootInterface) {
      return DBusMethodErrorResponse.notSupported();
    }
    if (call.interface != playerInterface)
      return DBusMethodErrorResponse.unknownInterface();
    final signature = switch (call.name) {
      'Play' || 'Pause' || 'PlayPause' || 'Stop' || 'Next' || 'Previous' => '',
      'Seek' => 'x',
      'SetPosition' => 'ox',
      _ => null,
    };
    if (signature == null) return DBusMethodErrorResponse.unknownMethod();
    if (call.signature != DBusSignature(signature))
      return DBusMethodErrorResponse.invalidArgs();
    return _command(() async {
      switch (call.name) {
        case 'Play':
          if (_canPlay && !_playing) await _play();
        case 'Pause':
          if (_canPlay && _playing) await _playback.pause();
        case 'PlayPause':
          if (_canPlay) {
            if (_playing) {
              await _playback.pause();
            } else {
              await _play();
            }
          }
        case 'Stop':
          if (_canPlay) await _playback.stop();
        case 'Next':
          await _queue.next(play: _playing);
        case 'Previous':
          await _queue.previous(play: _playing);
        case 'Seek':
          if (!_canSeek) return;
          final target =
              _playback.state.position +
              Duration(microseconds: call.values[0].asInt64());
          if (target > _playback.state.duration) {
            await _queue.next(play: _playing);
          } else {
            await _seek(target < Duration.zero ? Duration.zero : target);
          }
        case 'SetPosition':
          if (!_canSeek || call.values[0].asObjectPath().value != _trackId)
            return;
          final target = Duration(microseconds: call.values[1].asInt64());
          if (target >= Duration.zero && target <= _playback.state.duration)
            await _seek(target);
      }
    });
  }

  Future<void> _play() async {
    if (_playback.state.status == PlaybackStatus.stopped &&
        _queue.state.currentIndex >= 0) {
      // The engine releases its source on Stop, so reload the current queue slot.
      await _queue.playAt(_queue.state.currentIndex);
    } else {
      if (_playback.state.completed) await _playback.seek(Duration.zero);
      await _playback.play();
    }
  }

  Future<void> _seek(Duration position) async {
    await _playback.seek(position);
    await emitSignal(playerInterface, 'Seeked', [
      DBusInt64(position.inMicroseconds),
    ]);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _starting;
    } catch (_) {
      /* Already reported at startup. */
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _commands;
    await _signals;
    await _bus.close();
  }
}
