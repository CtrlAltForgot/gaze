class SavedJellyfinConnection {
  const SavedJellyfinConnection({
    required this.serverAddress,
    required this.accessToken,
    required this.userId,
    required this.userName,
  });

  final String serverAddress;
  final String accessToken;
  final String userId;
  final String userName;
}

abstract interface class JellyfinCredentialStore {
  Future<String> getOrCreateDeviceId();

  Future<SavedJellyfinConnection?> readConnection();

  Future<void> writeConnection(SavedJellyfinConnection connection);

  Future<void> deleteConnection();
}
