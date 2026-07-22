import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'jellyfin_api.dart';

class HttpJellyfinApi implements JellyfinApi {
  HttpJellyfinApi({
    required http.Client client,
    required JellyfinClientIdentity identity,
    this.requestTimeout = const Duration(seconds: 12),
  }) : _client = client,
       _identity = identity {
    _validateIdentity(identity);
  }

  final http.Client _client;
  final JellyfinClientIdentity _identity;
  final Duration requestTimeout;

  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) async {
    final response = await _request(
      () => _client.get(
        address.endpoint('/System/Info/Public'),
        headers: const {'Accept': 'application/json'},
      ),
    );
    _requireSuccess(response, operation: 'contact the Jellyfin server');
    final json = _decodeObject(response.body);
    return JellyfinServerInfo(
      id: _requiredString(json, 'Id'),
      name: _requiredString(json, 'ServerName'),
      version: _requiredString(json, 'Version'),
    );
  }

  @override
  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  }) async {
    final trimmedUserName = userName.trim();
    if (trimmedUserName.isEmpty || password.isEmpty) {
      throw const JellyfinConnectionException(
        'Enter both a Jellyfin username and password.',
      );
    }

    final response = await _request(
      () => _client.post(
        address.endpoint('/Users/AuthenticateByName'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': _authorizationHeader(),
        },
        body: jsonEncode({'Username': trimmedUserName, 'Pw': password}),
      ),
    );
    _requireSuccess(response, operation: 'sign in to Jellyfin');
    final json = _decodeObject(response.body);
    final user = json['User'];
    if (user is! Map<String, dynamic>) {
      throw const JellyfinConnectionException(
        'Jellyfin returned an incomplete authentication response.',
      );
    }
    return JellyfinSession(
      accessToken: _requiredString(json, 'AccessToken'),
      userId: _requiredString(user, 'Id'),
      userName: _requiredString(user, 'Name'),
    );
  }

  String _authorizationHeader({String? token}) {
    final values = [
      'Client="${_quote(_identity.clientName)}"',
      'Device="${_quote(_identity.deviceName)}"',
      'DeviceId="${_quote(_identity.deviceId)}"',
      'Version="${_quote(_identity.version)}"',
      if (token != null) 'Token="${_quote(token)}"',
    ];
    return 'MediaBrowser ${values.join(', ')}';
  }

  Future<http.Response> _request(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request().timeout(requestTimeout);
    } on TimeoutException {
      throw const JellyfinConnectionException(
        'The Jellyfin server did not respond in time.',
      );
    } on http.ClientException {
      throw const JellyfinConnectionException(
        'Could not reach the Jellyfin server.',
      );
    }
  }

  void _requireSuccess(http.Response response, {required String operation}) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JellyfinConnectionException(
        'Could not $operation (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
  }

  Map<String, dynamic> _decodeObject(String body) {
    try {
      final value = jsonDecode(body);
      if (value is Map<String, dynamic>) {
        return value;
      }
    } on FormatException {
      // The safe error below intentionally excludes the private response body.
    }
    throw const JellyfinConnectionException(
      'Jellyfin returned a response that gaze could not understand.',
    );
  }

  String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw const JellyfinConnectionException(
      'Jellyfin returned an incomplete response.',
    );
  }

  static void _validateIdentity(JellyfinClientIdentity identity) {
    for (final value in [
      identity.clientName,
      identity.deviceName,
      identity.deviceId,
      identity.version,
    ]) {
      if (value.isEmpty || value.contains('\r') || value.contains('\n')) {
        throw ArgumentError(
          'Jellyfin client identity values must be non-empty.',
        );
      }
    }
  }

  String _quote(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  @override
  void close() => _client.close();
}
