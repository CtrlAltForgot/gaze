import 'dart:convert';
import 'package:http/http.dart' as http;

abstract interface class GazeServiceApi {
  Future<Map<String, dynamic>> request(
    Uri address,
    String token,
    String path, {
    Map<String, dynamic>? body,
  });
  void close();
}

class GazeServiceException implements Exception {
  const GazeServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HttpGazeServiceApi implements GazeServiceApi {
  HttpGazeServiceApi(this.client);
  final http.Client client;
  @override
  Future<Map<String, dynamic>> request(
    Uri address,
    String token,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final url = address.replace(
      path: '${address.path.replaceAll(RegExp(r'/$'), '')}$path',
    );
    try {
      final headers = {
        'Authorization': 'Bearer $token',
        if (body != null) 'Content-Type': 'application/json',
      };
      final response =
          await (body == null
                  ? client.get(url, headers: headers)
                  : client.post(url, headers: headers, body: jsonEncode(body)))
              .timeout(const Duration(seconds: 30));
      final value = jsonDecode(response.body);
      if (value is! Map<String, dynamic>)
        throw const GazeServiceException(
          'gaze returned incomplete connection information.',
        );
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw GazeServiceException(
          value['error'] is String
              ? value['error'] as String
              : 'gaze could not save this change.',
        );
      return value;
    } on GazeServiceException {
      rethrow;
    } catch (_) {
      throw const GazeServiceException(
        'The gaze service is unavailable. Your saved imports and playlists stay on the server.',
      );
    }
  }

  @override
  void close() => client.close();
}
