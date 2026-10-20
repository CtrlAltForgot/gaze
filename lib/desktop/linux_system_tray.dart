import 'dart:async';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../playback/playback_controller.dart';
import '../playback/playback_queue_controller.dart';
import 'desktop_window.dart';

/// StatusNotifierItem/DBusMenu adapter used by KDE Plasma and compatible hosts.
/// A host must acknowledge registration before closing can hide the window.
class LinuxSystemTray {
  LinuxSystemTray({
    required PlaybackController playback,
    required PlaybackQueueController queue,
    required DBusClient bus,
    required DesktopWindow window,
    required Future<void> Function() onQuit,
    this.hostCheckInterval = const Duration(seconds: 10),
  }) : _playback = playback,
       _queue = queue,
       _bus = bus,
       _window = window,
       _onQuit = onQuit;

  static const watcherName = 'org.kde.StatusNotifierWatcher';
  static const itemInterface = 'org.kde.StatusNotifierItem';
  static const menuInterface = 'com.canonical.dbusmenu';
  static final itemPath = DBusObjectPath('/StatusNotifierItem');
  static final menuPath = DBusObjectPath('/Menu');
  final PlaybackController _playback;
  final PlaybackQueueController _queue;
  final DBusClient _bus;
  final DesktopWindow _window;
  final Future<void> Function() _onQuit;
  final Duration hostCheckInterval;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late final _TrayItem _item = _TrayItem(this);
  late final _TrayMenu _menu = _TrayMenu(this);
  late final _watcher = DBusRemoteObject(
    _bus,
    name: watcherName,
    path: DBusObjectPath('/StatusNotifierWatcher'),
  );
  Timer? _hostTimer;
  Future<void>? _starting;
  Future<void> _hostChecks = Future.value();
  Future<void> _commands = Future.value();
  Future<void> _signals = Future.value();
  String? _registeredOwner;
  bool? _available;
  bool _disposed = false;
  Map<int, Map<String, DBusValue>> _published = {};

  String get busName => _bus.uniqueName;
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    await _setAvailable(false);
    try {
      await _bus.registerObject(_item);
      await _bus.registerObject(_menu);
      _subscriptions.add(
        _bus.nameOwnerChanged.listen((event) {
          if (event.name == watcherName) {
            _registeredOwner = null;
            unawaited(_refreshHost());
          }
        }),
      );
      for (final name in [
        'StatusNotifierHostRegistered',
        'StatusNotifierHostUnregistered',
      ]) {
        _subscriptions.add(
          DBusRemoteObjectSignalStream(
            object: _watcher,
            interface: watcherName,
            name: name,
          ).listen((_) => unawaited(_refreshHost())),
        );
      }
      _published = _entries;
      _subscriptions.add(_playback.states.listen((_) => _publish()));
      _subscriptions.add(_queue.states.listen((_) => _publish()));
      await _refreshHost();
      if (_disposed) return;
      _hostTimer = Timer.periodic(hostCheckInterval, (_) {
        unawaited(_refreshHost());
      });
    } catch (_) {
      await _setAvailable(false);
      rethrow;
    }
  }

  Future<void> _refreshHost() {
    _hostChecks = _hostChecks
        .then((_) async {
          if (_disposed) return;
          try {
            final owner = await _bus
                .getNameOwner(watcherName)
                .timeout(const Duration(seconds: 2));
            if (owner == null) {
              _registeredOwner = null;
              await _setAvailable(false);
              return;
            }
            if (owner != _registeredOwner) {
              await _setAvailable(false);
              await _watcher
                  .callMethod(
                    watcherName,
                    'RegisterStatusNotifierItem',
                    [DBusString(itemPath.value)],
                    replySignature: DBusSignature(''),
                  )
                  .timeout(const Duration(seconds: 2));
              _registeredOwner = owner;
            }
            final hosted = await _watcher
                .getProperty(
                  watcherName,
                  'IsStatusNotifierHostRegistered',
                  signature: DBusSignature('b'),
                )
                .timeout(const Duration(seconds: 2));
            await _setAvailable(hosted.asBoolean());
          } catch (_) {
            _registeredOwner = null;
            await _setAvailable(false);
          }
        })
        .catchError((Object _) {
          // Window integration failing must never affect audio playback.
        });
    return _hostChecks;
  }

  Future<void> _setAvailable(bool available) async {
    if (_disposed && available || _available == available) return;
    await _window.setTrayAvailable(available);
    _available = available;
  }

  bool get _playing => switch (_playback.state.status) {
    PlaybackStatus.playing || PlaybackStatus.buffering => true,
    _ => false,
  };
  bool get _canPlay =>
      _playback.state.sourceLabel != null &&
      _playback.state.status != PlaybackStatus.loading &&
      _playback.state.status != PlaybackStatus.error;
  bool get _canPrevious =>
      _queue.state.hasPrevious ||
      (_canPlay &&
          _playback.state.position >
              PlaybackQueueController.previousRestartThreshold);

  Map<int, Map<String, DBusValue>> get _entries => {
    0: {'children-display': const DBusString('submenu')},
    1: {
      'label': const DBusString('Show gaze'),
      'icon-name': const DBusString('view-restore'),
    },
    2: {'type': const DBusString('separator')},
    3: {
      'label': DBusString(_playing ? 'Pause' : 'Play'),
      'enabled': DBusBoolean(_canPlay),
      'icon-name': DBusString(
        _playing ? 'media-playback-pause' : 'media-playback-start',
      ),
    },
    4: {
      'label': const DBusString('Previous'),
      'enabled': DBusBoolean(_canPrevious),
      'icon-name': const DBusString('media-skip-backward'),
    },
    5: {
      'label': const DBusString('Next'),
      'enabled': DBusBoolean(_queue.state.hasNext),
      'icon-name': const DBusString('media-skip-forward'),
    },
    6: {'type': const DBusString('separator')},
    7: {
      'label': const DBusString('Quit gaze'),
      'icon-name': const DBusString('application-exit'),
    },
  };

  Future<DBusMethodResponse> _command(int id) async {
    if (id == 7) {
      // Reply before quitting closes this D-Bus connection. Disposal must not
      // await the command that is itself requesting disposal.
      if (!_disposed) {
        unawaited(
          Future<void>(() async {
            try {
              await _onQuit();
            } catch (_) {
              await _window.show();
            }
          }),
        );
      }
      return DBusMethodSuccessResponse();
    }
    final result = _commands.then<DBusMethodResponse>((_) async {
      if (_disposed) return DBusMethodErrorResponse.failed();
      try {
        switch (id) {
          case 1:
            await _window.show();
          case 3:
            if (!_canPlay) break;
            if (_playing) {
              await _playback.pause();
            } else if (_playback.state.status == PlaybackStatus.stopped &&
                _queue.state.currentIndex >= 0) {
              await _queue.playAt(_queue.state.currentIndex);
            } else {
              if (_playback.state.completed)
                await _playback.seek(Duration.zero);
              await _playback.play();
            }
          case 4:
            if (_canPrevious) await _queue.previous(play: _playing);
          case 5:
            if (_queue.state.hasNext) await _queue.next(play: _playing);
        }
        return DBusMethodSuccessResponse();
      } catch (_) {
        return DBusMethodErrorResponse.failed('Tray action failed.');
      }
    });
    _commands = result.then((_) {});
    return result;
  }

  void _publish() {
    if (_disposed) return;
    final current = _entries;
    final changed = [
      for (final entry in current.entries)
        if (DBusDict.stringVariant(_published[entry.key] ?? {}) !=
            DBusDict.stringVariant(entry.value))
          DBusStruct([
            DBusInt32(entry.key),
            DBusDict.stringVariant(entry.value),
          ]),
    ];
    _published = current;
    if (changed.isEmpty) return;
    _signals = _signals
        .then((_) async {
          if (_disposed) return;
          await _menu.emitSignal(menuInterface, 'ItemsPropertiesUpdated', [
            DBusArray(DBusSignature('(ia{sv})'), changed),
            DBusArray(DBusSignature('(ias)'), []),
          ]);
        })
        .catchError((Object _) {});
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _hostTimer?.cancel();
    try {
      await _starting;
    } catch (_) {
      /* Startup already reported. */
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _hostChecks;
    await _commands;
    await _signals;
    await _bus.close();
  }
}

abstract class _TrayObject extends DBusObject {
  _TrayObject(super.path, this.interfaceName);
  final String interfaceName;
  Map<String, DBusValue> get properties;
  List<DBusIntrospectProperty> get propertyDescriptions => [
    for (final entry in properties.entries)
      DBusIntrospectProperty(
        entry.key,
        entry.value.signature,
        access: DBusPropertyAccess.read,
      ),
  ];
  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != interfaceName)
      return DBusMethodErrorResponse.unknownInterface();
    final value = properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface != interfaceName
      ? DBusMethodErrorResponse.unknownInterface()
      : DBusGetAllPropertiesResponse(properties);
}

class _TrayItem extends _TrayObject {
  _TrayItem(this.tray)
    : super(LinuxSystemTray.itemPath, LinuxSystemTray.itemInterface);
  final LinuxSystemTray tray;
  static final _pixmaps = DBusArray(DBusSignature('(iiay)'), [
    for (final size in [22, 32, 64])
      DBusStruct([
        DBusInt32(size),
        DBusInt32(size),
        DBusArray.byte(_icon(size)),
      ]),
  ]);
  @override
  Map<String, DBusValue> get properties => {
    'Category': const DBusString('ApplicationStatus'),
    'Id': const DBusString('gaze'),
    'Title': const DBusString('gaze'),
    'Status': const DBusString('Active'),
    'WindowId': const DBusUint32(0),
    'IconName': const DBusString(''),
    'IconPixmap': _pixmaps,
    'OverlayIconName': const DBusString(''),
    'OverlayIconPixmap': DBusArray(DBusSignature('(iiay)'), []),
    'AttentionIconName': const DBusString(''),
    'AttentionIconPixmap': DBusArray(DBusSignature('(iiay)'), []),
    'AttentionMovieName': const DBusString(''),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': LinuxSystemTray.menuPath,
    'ToolTip': DBusStruct([
      const DBusString(''),
      _pixmaps,
      const DBusString('gaze'),
      const DBusString('Show gaze and playback controls.'),
    ]),
  };
  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      interfaceName,
      properties: propertyDescriptions,
      methods: [
        for (final name in ['Activate', 'SecondaryActivate', 'ContextMenu'])
          _method(name, ['i', 'i']),
        _method('Scroll', ['i', 's']),
      ],
    ),
  ];
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != interfaceName)
      return DBusMethodErrorResponse.unknownInterface();
    final signature = switch (call.name) {
      'Activate' || 'SecondaryActivate' || 'ContextMenu' => 'ii',
      'Scroll' => 'is',
      _ => null,
    };
    if (signature == null) return DBusMethodErrorResponse.unknownMethod();
    if (call.signature != DBusSignature(signature))
      return DBusMethodErrorResponse.invalidArgs();
    if (call.name == 'SecondaryActivate') return tray._command(3);
    if (call.name == 'Activate') return tray._command(1);
    // Compatible hosts render our exported DBusMenu directly. If a host cannot
    // do that, keeping the main controls accessible is preferable to no action.
    if (call.name == 'ContextMenu') return tray._command(1);
    return DBusMethodSuccessResponse();
  }
}

class _TrayMenu extends _TrayObject {
  _TrayMenu(this.tray)
    : super(LinuxSystemTray.menuPath, LinuxSystemTray.menuInterface);
  final LinuxSystemTray tray;
  @override
  Map<String, DBusValue> get properties => {
    'Version': const DBusUint32(3),
    'TextDirection': const DBusString('ltr'),
    'Status': const DBusString('normal'),
    'IconThemePath': DBusArray.string([]),
  };
  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      interfaceName,
      properties: propertyDescriptions,
      methods: [
        _method('GetLayout', ['i', 'i', 'as'], ['u', '(ia{sv}av)']),
        _method('GetGroupProperties', ['ai', 'as'], ['a(ia{sv})']),
        _method('GetProperty', ['i', 's'], ['v']),
        _method('Event', ['i', 's', 'v', 'u']),
        _method('EventGroup', ['a(isvu)'], ['ai']),
        _method('AboutToShow', ['i'], ['b']),
        _method('AboutToShowGroup', ['ai'], ['ai', 'ai']),
      ],
      signals: [
        DBusIntrospectSignal(
          'ItemsPropertiesUpdated',
          args: [
            _argument('a(ia{sv})', output: true),
            _argument('a(ias)', output: true),
          ],
        ),
        DBusIntrospectSignal(
          'LayoutUpdated',
          args: [_argument('u', output: true), _argument('i', output: true)],
        ),
      ],
    ),
  ];
  Map<String, DBusValue> _properties(int id, List<String> names) => {
    for (final entry in tray._entries[id]!.entries)
      if (names.isEmpty || names.contains(entry.key)) entry.key: entry.value,
  };
  DBusStruct _layout(int id, int depth, List<String> names) => DBusStruct([
    DBusInt32(id),
    DBusDict.stringVariant(_properties(id, names)),
    DBusArray(DBusSignature('v'), [
      if (id == 0 && depth != 0)
        for (final child in tray._entries.keys.skip(1))
          DBusVariant(_layout(child, depth - 1, names)),
    ]),
  ]);
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != interfaceName)
      return DBusMethodErrorResponse.unknownInterface();
    final signature = switch (call.name) {
      'GetLayout' => 'iias',
      'GetGroupProperties' => 'aias',
      'GetProperty' => 'is',
      'Event' => 'isvu',
      'EventGroup' => 'a(isvu)',
      'AboutToShow' => 'i',
      'AboutToShowGroup' => 'ai',
      _ => null,
    };
    if (signature == null) return DBusMethodErrorResponse.unknownMethod();
    if (call.signature != DBusSignature(signature))
      return DBusMethodErrorResponse.invalidArgs();
    final args = call.values;
    switch (call.name) {
      case 'GetLayout':
        final id = args[0].asInt32();
        if (!tray._entries.containsKey(id))
          return DBusMethodErrorResponse.invalidArgs();
        return DBusMethodSuccessResponse([
          const DBusUint32(1),
          _layout(id, args[1].asInt32(), args[2].asStringArray().toList()),
        ]);
      case 'GetGroupProperties':
        final ids = args[0].asInt32Array().toList();
        final names = args[1].asStringArray().toList();
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in ids.isEmpty ? tray._entries.keys : ids)
              if (tray._entries.containsKey(id))
                DBusStruct([
                  DBusInt32(id),
                  DBusDict.stringVariant(_properties(id, names)),
                ]),
          ]),
        ]);
      case 'GetProperty':
        final value = tray._entries[args[0].asInt32()]?[args[1].asString()];
        return value == null
            ? DBusMethodErrorResponse.unknownProperty()
            : DBusMethodSuccessResponse([DBusVariant(value)]);
      case 'Event':
        if (!tray._entries.containsKey(args[0].asInt32()))
          return DBusMethodErrorResponse.invalidArgs();
        if (args[1].asString() == 'clicked')
          return tray._command(args[0].asInt32());
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        final errors = <int>[];
        for (final event in (args[0] as DBusArray).children) {
          final values = (event as DBusStruct).children;
          final id = values[0].asInt32();
          if (!tray._entries.containsKey(id)) {
            errors.add(id);
          } else if (values[1].asString() == 'clicked') {
            final response = await tray._command(id);
            if (response is DBusMethodErrorResponse) errors.add(id);
          }
        }
        return DBusMethodSuccessResponse([DBusArray.int32(errors)]);
      case 'AboutToShow':
        if (!tray._entries.containsKey(args[0].asInt32()))
          return DBusMethodErrorResponse.invalidArgs();
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'AboutToShowGroup':
        return DBusMethodSuccessResponse([
          DBusArray.int32([]),
          DBusArray.int32([
            for (final id in args[0].asInt32Array())
              if (!tray._entries.containsKey(id)) id,
          ]),
        ]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

DBusIntrospectArgument _argument(String signature, {bool output = false}) =>
    DBusIntrospectArgument(
      DBusSignature(signature),
      output ? DBusArgumentDirection.out : DBusArgumentDirection.in_,
    );
DBusIntrospectMethod _method(
  String name,
  List<String> input, [
  List<String> output = const [],
]) => DBusIntrospectMethod(
  name,
  args: [
    for (final type in input) _argument(type),
    for (final type in output) _argument(type, output: true),
  ],
);

/// Small bundled note icon in network-order ARGB, as required by SNI. No theme
/// dependency or network artwork request can leave the tray without an icon.
Uint8List _icon(int size) {
  final bytes = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = (x + .5) / size;
      final dy = (y + .5) / size;
      final circle = (dx - .5) * (dx - .5) + (dy - .5) * (dy - .5) < .235;
      final stem = dx > .53 && dx < .61 && dy > .22 && dy < .64;
      final flag = dx > .56 && dx < .76 && dy > .22 && dy < .33;
      final note =
          (dx - .43) * (dx - .43) / .025 + (dy - .65) * (dy - .65) / .017 < 1;
      final index = (y * size + x) * 4;
      bytes[index] = circle ? 255 : 0;
      final light = stem || flag || note;
      bytes[index + 1] = light ? 255 : 171;
      bytes[index + 2] = light ? 255 : 125;
      bytes[index + 3] = light ? 255 : 241;
    }
  }
  return bytes;
}
