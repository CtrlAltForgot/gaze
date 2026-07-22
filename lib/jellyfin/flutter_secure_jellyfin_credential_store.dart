import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'jellyfin_credential_store.dart';

class FlutterSecureJellyfinCredentialStore implements JellyfinCredentialStore {
  const FlutterSecureJellyfinCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _accessTokenKey = 'gaze.jellyfin.access_token';
  static const _deviceIdKey = 'gaze.installation.device_id';

  final FlutterSecureStorage _storage;

  @override
  Future<String> getOrCreateDeviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final random = Random.secure();
    final deviceId = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _storage.write(key: _deviceIdKey, value: deviceId);
    return deviceId;
  }

  @override
  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);

  @override
  Future<void> writeAccessToken(String token) =>
      _storage.write(key: _accessTokenKey, value: token);

  @override
  Future<void> deleteAccessToken() => _storage.delete(key: _accessTokenKey);
}
