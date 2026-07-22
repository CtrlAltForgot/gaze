abstract interface class JellyfinCredentialStore {
  Future<String> getOrCreateDeviceId();

  Future<String?> readAccessToken();

  Future<void> writeAccessToken(String token);

  Future<void> deleteAccessToken();
}
