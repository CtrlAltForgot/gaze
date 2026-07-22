import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/http_jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('JellyfinServerAddress', () {
    test('accepts and normalizes HTTP and HTTPS addresses', () {
      final httpAddress = JellyfinServerAddress.parse(
        'http://music.local:8096/',
      );
      final httpsAddress = JellyfinServerAddress.parse(
        'https://music.example/jellyfin/',
      );

      expect(httpAddress.isEncrypted, isFalse);
      expect(httpAddress.toString(), 'http://music.local:8096');
      expect(
        httpsAddress.endpoint('/System/Info/Public').toString(),
        'https://music.example/jellyfin/System/Info/Public',
      );
    });

    test('rejects unsafe or unsupported address forms', () {
      for (final value in [
        'music.local:8096',
        'ftp://music.local',
        'http://user:password@music.local',
        'http://music.local?token=secret',
      ]) {
        expect(
          () => JellyfinServerAddress.parse(value),
          throwsA(isA<JellyfinConnectionException>()),
        );
      }
    });
  });

  group('HttpJellyfinApi', () {
    test('reads public Jellyfin server information over HTTP', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'http://music.local:8096/System/Info/Public',
        );
        return http.Response(
          jsonEncode({
            'Id': 'server-id',
            'ServerName': 'Music Server',
            'Version': '10.11.0',
          }),
          200,
        );
      });
      final api = _createApi(client);

      final info = await api.getPublicServerInfo(
        JellyfinServerAddress.parse('http://music.local:8096'),
      );

      expect(info.id, 'server-id');
      expect(info.name, 'Music Server');
      expect(info.version, '10.11.0');
      api.close();
    });

    test('authenticates without putting credentials in the URL', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://music.example/Users/AuthenticateByName',
        );
        expect(request.url.userInfo, isEmpty);
        expect(
          request.headers['authorization'],
          'MediaBrowser Client="gaze", Device="test desktop", '
          'DeviceId="test-device-id", Version="0.1.0"',
        );
        expect(jsonDecode(request.body), {
          'Username': 'listener',
          'Pw': 'private-password',
        });
        return http.Response(
          jsonEncode({
            'AccessToken': 'private-access-token',
            'User': {'Id': 'user-id', 'Name': 'listener'},
          }),
          200,
        );
      });
      final api = _createApi(client);

      final session = await api.authenticate(
        address: JellyfinServerAddress.parse('https://music.example'),
        userName: 'listener',
        password: 'private-password',
      );

      expect(session.accessToken, 'private-access-token');
      expect(session.userId, 'user-id');
      expect(session.userName, 'listener');
      api.close();
    });

    test('reports HTTP status without exposing a private response', () async {
      final client = MockClient(
        (_) async => http.Response('private server response', 401),
      );
      final api = _createApi(client);

      await expectLater(
        api.authenticate(
          address: JellyfinServerAddress.parse('http://music.local:8096'),
          userName: 'listener',
          password: 'wrong-password',
        ),
        throwsA(
          isA<JellyfinConnectionException>()
              .having((error) => error.statusCode, 'status code', 401)
              .having(
                (error) => error.message,
                'safe message',
                allOf(contains('HTTP 401'), isNot(contains('private server'))),
              ),
        ),
      );
      api.close();
    });

    test('rejects malformed successful responses safely', () async {
      final client = MockClient((_) async => http.Response('not json', 200));
      final api = _createApi(client);

      await expectLater(
        api.getPublicServerInfo(
          JellyfinServerAddress.parse('http://music.local:8096'),
        ),
        throwsA(
          isA<JellyfinConnectionException>().having(
            (error) => error.message,
            'message',
            isNot(contains('not json')),
          ),
        ),
      );
      api.close();
    });
  });
}

HttpJellyfinApi _createApi(http.Client client) {
  return HttpJellyfinApi(
    client: client,
    identity: const JellyfinClientIdentity(
      clientName: 'gaze',
      deviceName: 'test desktop',
      deviceId: 'test-device-id',
      version: '0.1.0',
    ),
  );
}
