import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class PartyException implements Exception {
  const PartyException(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => message;
}

class PartyInvite {
  const PartyInvite(this.server, this.id, this.secret);
  final Uri server;
  final String id;
  final String secret;
  static PartyInvite parse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null)
      throw const PartyException('Paste a complete gaze invitation.');
    final Uri? server;
    final String? id;
    if (uri.scheme == 'gaze' &&
        uri.host == 'party' &&
        uri.pathSegments.length == 1) {
      server = Uri.tryParse(uri.queryParameters['server'] ?? '');
      id = uri.pathSegments.first;
    } else if (uri.scheme == 'https' &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'party' &&
        !uri.hasQuery) {
      server = uri.removeFragment().replace(path: '');
      id = uri.pathSegments.last;
    } else {
      throw const PartyException(
        'This is not a gaze Party Session invitation.',
      );
    }
    if (server == null ||
        server.scheme != 'https' ||
        server.host.isEmpty ||
        server.userInfo.isNotEmpty ||
        (server.path.isNotEmpty && server.path != '/') ||
        server.hasQuery ||
        server.hasFragment ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !RegExp(r'^[\w-]{43}$').hasMatch(uri.fragment)) {
      throw const PartyException('This invitation is incomplete or invalid.');
    }
    return PartyInvite(server, id, uri.fragment);
  }
}

abstract interface class PartyApi {
  Future<Map<String, dynamic>> request(
    Uri server,
    String token,
    String path, {
    Map<String, dynamic>? body,
  });
  Future<Uint8List?> artwork(Uri uri, String token);
  void close();
}

class HttpPartyApi implements PartyApi {
  HttpPartyApi(this.client);
  final http.Client client;
  @override
  Future<Map<String, dynamic>> request(
    Uri server,
    String token,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    try {
      final request =
          http.Request(
              body == null ? 'GET' : 'POST',
              server.replace(
                path: Uri.parse(path).path,
                query: Uri.parse(path).query.isEmpty
                    ? null
                    : Uri.parse(path).query,
                fragment: null,
              ),
            )
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            });
      if (body != null) request.body = jsonEncode(body);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024)
          throw const PartyException('This session is too large.');
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>)
        throw const PartyException('The session returned an invalid response.');
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw PartyException(
          value['error'] is String
              ? value['error']
              : 'The session is unavailable.',
          response.statusCode,
        );
      return value;
    } on PartyException {
      rethrow;
    } catch (_) {
      throw const PartyException(
        'Could not reach the Party Session. Reconnecting…',
      );
    }
  }

  @override
  Future<Uint8List?> artwork(Uri uri, String token) async {
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $token';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 10),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 12 * 1024 * 1024) return null;
      }
      return response.statusCode == 200 ? Uint8List.fromList(bytes) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void close() => client.close();
}
