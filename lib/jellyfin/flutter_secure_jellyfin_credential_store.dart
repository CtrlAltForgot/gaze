import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'jellyfin_credential_store.dart';

class FlutterSecureJellyfinCredentialStore implements JellyfinCredentialStore {
  const FlutterSecureJellyfinCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _connectionKey = 'gaze.jellyfin.connection';
  static const _profileKey = 'gaze.jellyfin.profile';
  static const _legacyAccessTokenKey = 'gaze.jellyfin.access_token';
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
  Future<SavedJellyfinConnection?> readConnection() async {
    final encoded = await _storage.read(key: _connectionKey);
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic>) {
        return null;
      }
      final serverAddress = value['serverAddress'];
      final accessToken = value['accessToken'];
      final userId = value['userId'];
      final userName = value['userName'];
      if (serverAddress is! String ||
          accessToken is! String ||
          userId is! String ||
          userName is! String ||
          serverAddress.isEmpty ||
          accessToken.isEmpty ||
          userId.isEmpty ||
          userName.isEmpty) {
        return null;
      }
      return SavedJellyfinConnection(
        serverAddress: serverAddress,
        accessToken: accessToken,
        userId: userId,
        userName: userName,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<SavedJellyfinProfile?> readProfile() async {
    final encoded = await _storage.read(key: _profileKey);
    if (encoded == null || encoded.isEmpty) {
      final connection = await readConnection();
      return connection == null
          ? null
          : SavedJellyfinProfile(
              serverAddress: connection.serverAddress,
              userName: connection.userName,
            );
    }
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['serverAddress'] is! String ||
          value['userName'] is! String) {
        return null;
      }
      return SavedJellyfinProfile(
        serverAddress: value['serverAddress'] as String,
        userName: value['userName'] as String,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeConnection(SavedJellyfinConnection connection) async {
    await _storage.write(
      key: _connectionKey,
      value: jsonEncode({
        'serverAddress': connection.serverAddress,
        'accessToken': connection.accessToken,
        'userId': connection.userId,
        'userName': connection.userName,
      }),
    );
    try {
      await _storage.delete(key: _legacyAccessTokenKey);
    } on Exception {
      // The new session is already saved. Legacy cleanup must not reject login.
    }
  }

  @override
  Future<void> writeProfile(SavedJellyfinProfile profile) => _storage.write(
    key: _profileKey,
    value: jsonEncode({
      'serverAddress': profile.serverAddress,
      'userName': profile.userName,
    }),
  );

  @override
  Future<void> deleteConnection() async {
    await _storage.delete(key: _connectionKey);
    try {
      await _storage.delete(key: _legacyAccessTokenKey);
    } on Exception {
      // Best-effort cleanup for the pre-profile token format.
    }
  }
}
