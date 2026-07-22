# gaze Jellyfin connection foundation

## Status

Transport and temporary connection flow implemented and manually verified against the intended Jellyfin server on Linux. The flow validates the server address, discovers public server information, authenticates with username and password, stores only the returned access token and installation device ID in the operating system credential store, and exposes safe connection errors. The password is cleared after each attempt and is never persisted.

## Implemented in this increment

- `JellyfinServerAddress` validates and normalizes explicit HTTP and HTTPS addresses, including optional base paths.
- `JellyfinApi` defines the application-facing public-info and authentication boundary.
- `HttpJellyfinApi` uses an injected `package:http` client, safe timeouts, Jellyfin authorization headers, and response parsing that does not echo private bodies in errors.
- `JellyfinServerInfo` and `JellyfinSession` keep transport responses out of future widgets.
- Sanitized tests cover HTTP/HTTPS normalization, rejected unsafe address forms, public server discovery, authentication request shape, safe HTTP errors, and malformed responses.
- `flutter_secure_storage` keeps the access token and stable installation device ID out of ordinary files and preferences.
- A temporary, plainly labeled connection screen supports both HTTP and HTTPS, warns when HTTP is selected, and shows the connected server, user, and version.
- Controller and widget tests cover successful connection, secure-token lifecycle, disconnect, and safe failures without using a real server or credentials.

Connection-flow verification completed on Linux:

- `flutter pub get` — passed
- `dart format .` — passed
- `flutter analyze` — passed with no issues
- `flutter test` — passed, eight tests total
- `flutter build linux --debug` — passed

## Connection policy

- Accept explicit `http://` and `https://` server addresses.
- Preserve a configured base path, such as `http://server:8096/jellyfin`.
- Reject addresses with unsupported schemes, embedded usernames/passwords, query strings, or fragments.
- Never disable TLS certificate validation automatically. A certificate problem must produce a useful connection error.
- Plain HTTP is allowed because gaze initially connects to a Jellyfin server on the user's trusted local network. HTTP is unencrypted: credentials, access tokens, metadata, and audio traffic could be observed by another party with access to that network path. HTTPS should be preferred whenever the server is later exposed beyond the trusted LAN.
- Never commit or log the real server address, username, password, access token, authenticated stream URL, or personal library response.

## API flow

1. Normalize the user-entered server address.
2. Request `GET /System/Info/Public` to verify that the endpoint is a Jellyfin server and record its reported name, ID, and version.
3. Authenticate with `POST /Users/AuthenticateByName` using JSON fields `Username` and `Pw`.
4. Send Jellyfin's `MediaBrowser` authorization scheme with stable client, device, device-ID, and version values.
5. Parse the access token and user identity into a gaze session model.
6. Keep the password only for the duration of the authentication request.
7. Persist the access token and installation device ID through an operating-system credential-store adapter.
8. Manually validate authentication against the intended server without placing credentials in the repository or terminal.
9. Use the authenticated session to request one read-only music slice before expanding the API surface.

The Swagger UI hosted by the user's actual Jellyfin server at `/api-docs/swagger/index.html` is the version-specific reference. The Jellyfin server repository documents `/System/Info/Public`, `/Users/AuthenticateByName`, and `/Users/Me`; the generated API also exposes `/Audio/{itemId}/universal` for later authenticated playback.

## Dependency decisions

### HTTP

Use `package:http` 1.6.0, maintained by `dart.dev`. Its default `IOClient` supports Linux, Windows, and macOS. The `Client` interface can be replaced with a fake in tests and later with a platform-native implementation if a concrete proxy or certificate-store requirement emerges.

### Secure token storage

`flutter_secure_storage` 10.3.1 is used because its official package metadata supports Linux, Windows, and macOS and maps to platform credential mechanisms:

- Linux requires the `libsecret` runtime and `libsecret-devel` build package plus an available Secret Service provider. Both packages and `libsecret-1` pkg-config metadata are present on this Nobara development system.
- Windows requires later validation with the documented Visual Studio C++ ATL components.
- macOS requires later Keychain entitlement validation.

Windows and macOS storage behavior remains documentation-confirmed but untested until gaze is built and exercised on those operating systems.

## Security boundaries

- The server address is configuration, not a secret, but the user's real address still stays out of repository fixtures and documentation.
- Passwords are never persisted.
- Tokens are secrets and may not be stored in ordinary preferences, SQLite, logs, exception messages, or source code.
- HTTP error handling records status and safe context only; it does not echo response bodies that might contain private server information.
- Device identity must be stable per installation once persistence exists. Tests use generic fixed identifiers.

## Sources reviewed

- [Jellyfin server repository and hosted Swagger location](https://github.com/jellyfin/jellyfin)
- [Jellyfin devices documentation](https://jellyfin.org/docs/general/server/devices/)
- [`package:http` platform support](https://pub.dev/packages/http)
- [`flutter_secure_storage` platform support](https://pub.dev/packages/flutter_secure_storage)
- [`flutter_secure_storage` Linux requirements](https://pub.dev/packages/flutter_secure_storage/versions/10.3.1)
