class SavedJellyfinConnection {
  const SavedJellyfinConnection({
    required this.serverAddress,
    required this.accessToken,
    required this.userId,
    required this.userName,
    this.serverId,
    this.serverName,
    this.serverVersion,
  });

  final String serverAddress;
  final String accessToken;
  final String userId;
  final String userName;
  final String? serverId;
  final String? serverName;
  final String? serverVersion;
}

class SavedJellyfinProfile {
  const SavedJellyfinProfile({
    required this.serverAddress,
    required this.userName,
  });

  final String serverAddress;
  final String userName;
}

abstract interface class JellyfinCredentialStore {
  Future<String> getOrCreateDeviceId();

  Future<SavedJellyfinConnection?> readConnection();

  Future<SavedJellyfinProfile?> readProfile();

  Future<void> writeConnection(SavedJellyfinConnection connection);

  Future<void> writeProfile(SavedJellyfinProfile profile);

  Future<void> deleteConnection();
}
