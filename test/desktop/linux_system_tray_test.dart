import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/desktop_window.dart';
import 'package:gaze/desktop/linux_system_tray.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';

import 'linux_media_session_test.dart' show MediaKeyTestPlayback;

void main() {
  late Directory directory;
  late DBusServer server;
  late DBusAddress address;
  late DBusClient host;
  late DBusClient client;
  late _Watcher watcher;
  late _Window window;
  late MediaKeyTestPlayback playback;
  late PlaybackQueueController queue;
  late LinuxSystemTray tray;
  late DBusRemoteObject item;
  late DBusRemoteObject menu;
  var quitCount = 0;
  const itemInterface = LinuxSystemTray.itemInterface;
  const menuInterface = LinuxSystemTray.menuInterface;

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 100; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Desktop host state did not settle.');
  }

  Future<void> start({bool withHost = true}) async {
    if (withHost) {
      await host.requestName(LinuxSystemTray.watcherName);
    }
    await tray.start();
    item = DBusRemoteObject(
      client,
      name: tray.busName,
      path: LinuxSystemTray.itemPath,
    );
    menu = DBusRemoteObject(
      client,
      name: tray.busName,
      path: LinuxSystemTray.menuPath,
    );
  }

  Future<void> click(int id) async {
    await menu.callMethod(menuInterface, 'Event', [
      DBusInt32(id),
      const DBusString('clicked'),
      const DBusVariant(DBusInt32(0)),
      const DBusUint32(0),
    ], replySignature: DBusSignature(''));
  }

  Future<void> load() => queue.playAlbum([
    for (final title in ['One', 'Two', 'Three'])
      RemotePlaybackSource(
        uri: Uri.parse('https://private.invalid/$title'),
        title: title,
        artist: 'Artist',
        itemId: title,
        headers: {'Authorization': 'secret-never-exported'},
      ),
  ], startIndex: 0);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gaze-tray-test-');
    server = DBusServer();
    address = await server.listenAddress(
      DBusAddress.unix(path: '${directory.path}/bus'),
    );
    host = DBusClient(address);
    watcher = _Watcher();
    await host.registerObject(watcher);
    client = DBusClient(address);
    window = _Window();
    playback = MediaKeyTestPlayback();
    queue = PlaybackQueueController(playbackController: playback);
    quitCount = 0;
    tray = LinuxSystemTray(
      playback: playback,
      queue: queue,
      bus: DBusClient(address),
      window: window,
      onQuit: () async {
        quitCount++;
      },
    );
  });

  tearDown(() async {
    await tray.dispose();
    await client.close();
    await host.close();
    await queue.dispose();
    await playback.dispose();
    await server.close();
    await directory.delete(recursive: true);
  });

  test(
    'only hides after host registration; losing host restores access',
    () async {
      await load();
      await start(withHost: false);
      expect(window.availability, [false]);
      expect(playback.state.status, PlaybackStatus.playing);
      await host.requestName(LinuxSystemTray.watcherName);
      await waitFor(() => window.availability.last);
      expect(watcher.registrationPath, '/StatusNotifierItem');
      expect(watcher.registrationSender, tray.busName);
      await host.releaseName(LinuxSystemTray.watcherName);
      await waitFor(() => !window.availability.last);
      expect(playback.state.status, PlaybackStatus.playing);
      await host.requestName(LinuxSystemTray.watcherName);
      await waitFor(() => window.availability.last);
      expect(
        playback.commands.where((c) => c == 'pause' || c == 'stop'),
        isEmpty,
      );
    },
  );

  test(
    'watcher without a panel and rejected registration stay recoverable',
    () async {
      watcher.hosted = false;
      await start();
      expect(window.availability.last, isFalse);
      watcher.hosted = true;
      await watcher.emitSignal(
        LinuxSystemTray.watcherName,
        'StatusNotifierHostRegistered',
      );
      await waitFor(() => window.availability.last);
      watcher.hosted = false;
      await watcher.emitSignal(
        LinuxSystemTray.watcherName,
        'StatusNotifierHostUnregistered',
      );
      await waitFor(() => !window.availability.last);
      await host.releaseName(LinuxSystemTray.watcherName);
      watcher.reject = true;
      watcher.hosted = true;
      await host.requestName(LinuxSystemTray.watcherName);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(window.availability.last, isFalse);
    },
  );

  test('exports a complete safe icon and native menu tree', () async {
    await start();
    final props = await item.getAllProperties(itemInterface);
    expect(props['Id'], const DBusString('gaze'));
    expect(props['Menu'], LinuxSystemTray.menuPath);
    expect(props['ItemIsMenu'], const DBusBoolean(false));
    final icons = (props['IconPixmap']! as DBusArray).children;
    expect(icons.length, 3);
    for (final icon in icons) {
      final parts = (icon as DBusStruct).children;
      final size = parts[0].asInt32();
      expect(parts[2].asByteArray().length, size * size * 4);
    }
    expect(props.toString(), isNot(contains('private.invalid')));
    expect(props.toString(), isNot(contains('secret')));
    final description = await menu.introspect();
    expect(description.interfaces.map((i) => i.name), contains(menuInterface));
    final layout = await menu.callMethod(menuInterface, 'GetLayout', [
      const DBusInt32(0),
      const DBusInt32(-1),
      DBusArray.string([]),
    ], replySignature: DBusSignature('u(ia{sv}av)'));
    final root = (layout.returnValues[1] as DBusStruct).children;
    final children = (root[2] as DBusArray).children;
    final labels = children
        .map(
          (node) => ((node.asVariant() as DBusStruct).children[1])
              .asStringVariantDict()['label']
              ?.asString(),
        )
        .whereType<String>();
    expect(labels, ['Show gaze', 'Play', 'Previous', 'Next', 'Quit gaze']);
  });

  test(
    'tray activation restores and transport uses existing queue semantics',
    () async {
      await load();
      await start();
      await item.callMethod(itemInterface, 'Activate', [
        const DBusInt32(0),
        const DBusInt32(0),
      ]);
      expect(window.shows, 1);
      await click(3);
      expect(playback.state.status, PlaybackStatus.paused);
      await click(5);
      expect(playback.state.title, 'Two');
      expect(playback.state.status, PlaybackStatus.ready);
      await click(3);
      expect(playback.state.status, PlaybackStatus.playing);
      await Future.wait([click(5), click(4)]);
      expect(playback.state.title, 'Two');
      await playback.seek(const Duration(seconds: 10));
      await click(4);
      expect(playback.state.title, 'Two');
      expect(playback.state.position, Duration.zero);
      await click(7);
      await waitFor(() => quitCount == 1);
    },
  );

  test(
    'menu changes live and rejects malformed calls without affecting playback',
    () async {
      await start();
      for (final id in [3, 4, 5]) {
        await click(id);
      }
      expect(playback.commands, isEmpty);
      final signals = <DBusSignal>[];
      final subscription = DBusRemoteObjectSignalStream(
        object: menu,
        interface: menuInterface,
        name: 'ItemsPropertiesUpdated',
      ).listen(signals.add);
      await client.ping();
      await load();
      await click(3);
      await waitFor(() => signals.isNotEmpty);
      expect(
        signals.every((s) => s.signature == DBusSignature('a(ia{sv})a(ias)')),
        isTrue,
      );
      final label = await menu.callMethod(menuInterface, 'GetProperty', [
        const DBusInt32(3),
        const DBusString('label'),
      ], replySignature: DBusSignature('v'));
      expect(label.returnValues.single.asVariant(), const DBusString('Play'));
      await expectLater(
        menu.callMethod(menuInterface, 'GetLayout', [const DBusString('bad')]),
        throwsA(isA<DBusInvalidArgsException>()),
      );
      await expectLater(click(900), throwsA(isA<DBusInvalidArgsException>()));
      expect(playback.state.status, PlaybackStatus.paused);
      await subscription.cancel();
    },
  );
}

class _Window implements DesktopWindow {
  final availability = <bool>[];
  var shows = 0;
  @override
  Future<void> setTrayAvailable(bool available) async {
    availability.add(available);
  }

  @override
  Future<void> show() async {
    shows++;
  }

  @override
  Future<void> quit() async {}
}

class _Watcher extends DBusObject {
  _Watcher() : super(DBusObjectPath('/StatusNotifierWatcher'));
  var hosted = true;
  var reject = false;
  String? registrationPath;
  String? registrationSender;
  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      interface == LinuxSystemTray.watcherName &&
          name == 'IsStatusNotifierHostRegistered'
      ? DBusGetPropertyResponse(DBusBoolean(hosted))
      : DBusMethodErrorResponse.unknownProperty();
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != LinuxSystemTray.watcherName ||
        call.name != 'RegisterStatusNotifierItem') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (reject) return DBusMethodErrorResponse.failed();
    registrationPath = call.values.single.asString();
    registrationSender = call.sender;
    return DBusMethodSuccessResponse();
  }
}
