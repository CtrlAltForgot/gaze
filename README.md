# gaze

**Your music, brought forward.**

An independent desktop music player for the library you keep. Browse your
Jellyfin music, build playlists, follow synced lyrics, and listen together in a
Party Session. Built with Flutter, with an optional lightweight Node service.

[Website](https://music.tristans.house) · [Downloads](https://github.com/CtrlAltForgot/gaze/releases) · [Issues](https://github.com/CtrlAltForgot/gaze/issues)

## What’s here

- Cached library browsing, albums, separate artist pages, search, and playlists.
- Artwork-colored backgrounds, a compact player, and an expanded Media Mode.
- Timed lyrics with click-to-seek, shown in the center alongside your queue.
- Single-click to browse a playlist; double-click to play it, respecting shuffle.
- Party Sessions: share an invite from the queue; friends join without a library
  account, add songs, skip, go back, and edit the shared queue. Volume stays personal.
- Linux tray, media keys/MPRIS, integrated window controls, and `gaze://` invites.
- Optional service integrations for imports and missing artwork.

This is an early preview. Linux is the active development platform. Windows and
macOS source/build support is included; a successful CI build is not a claim
that playback or native window integration has been manually tested there.

## Install

Get a release from [Downloads](https://github.com/CtrlAltForgot/gaze/releases).

**Linux:** extract the Linux archive and run `./install.sh`. This installs into
your user account, adds the application launcher, and registers Party Session
links. Runtime requirements include GTK 3, libsecret, SQLite, and libmpv
(`mpv-libs` on Fedora/Nobara; `libmpv2` on Ubuntu). No root access is needed by
the installer; install missing runtime packages with your system’s package manager.
The standard Linux archive is built on Ubuntu 24.04. A separate Nobara 44
archive includes the high-refresh Linux engine. Older distributions may need
to build from source.

**Windows:** extract the complete archive, keep its DLLs and data beside
`gaze.exe`, and run it once to enable invitation links. Registration is for your
current user only and requires no administrator access. The included
`register-invites.ps1` can repair registration if needed. The release ZIP
includes the required Microsoft Visual C++ runtime files.

**macOS:** use the macOS build artifact or build locally. Preview builds are not
signed or notarized. Native behavior still needs testing on macOS.

To use your own library, select **Connect** and sign in to your Jellyfin server.
To join a friend, open their invite or paste it into **Queue → Party Session**.
Guests need no Jellyfin account. Everyone can control playback and search the host’s library; leaving restores
your own queue. Invite links grant access to that session’s queue until it ends
or expires, so share them only with intended listeners.

## Development

Use Flutter **3.44.7** (Dart 3.12.2 or compatible). Clone this repository, then:

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d linux
```

Use `-d windows` or `-d macos` on the corresponding operating system. Linux
build dependencies include clang, CMake, Ninja, pkg-config, GTK 3 development
headers, libsecret development headers, and libmpv. See the CI workflow for an
Ubuntu build environment. No mobile shell is provided.

```sh
dart format .
flutter build linux --release
node --test server/test/*.test.js
```

The service tests use Node 22+ and FFmpeg. Network/media boundaries are replaceable
with fakes. The Linux high-refresh engine patch is documented in
[packaging/linux](packaging/linux); an optional locally built engine is never
committed. Stock Flutter builds remain supported.

## Host a Party Session service

The app hosts through a gaze service connected to your Jellyfin server. A
standalone service does not need Synopti or Spotify:

```sh
docker build -f server/Dockerfile.party -t gaze-party ./server
docker run --rm -p 8097:8097 \
  -e JELLYFIN_URL=https://your-library.example \
  -e GAZE_PUBLIC_ORIGIN=https://music.example \
  -e GAZE_PARTY_GUESTS=true gaze-party
```

Publish the service through a dedicated HTTPS reverse proxy or Cloudflare Tunnel,
then save its address in gaze’s **Connect** screen. No Jellyfin credentials are
needed in that Docker command. Host authentication happens through the app.
The service validates the host’s library and gives guests expiring, session-only
audio access. API and audio responses must not be cached by the proxy.

The root and invitation URLs serve the included landing page. A Linux/macOS/
Windows protocol handler opens installed gaze; the page links to downloads when
it isn’t installed. Read [Party Sessions](docs/PARTY_SESSIONS.md) for protocol,
limits, reconnect behavior, and deployment details. The full optional import
service and its additional prerequisites are described in [server/README.md](server/README.md).

## Privacy and project status

Account credentials use the operating system’s credential store. Guest tokens
stay in memory. Short invitation codes grant access until the session ends. Library caches
and audio stay out of this repository. LRCLIB can receive song metadata to find
missing lyrics; no account credentials or audio are sent. Public artist-profile
lookup is off by default. The optional missing-artwork search uses public music
catalogs as documented in the service guide.

There is no telemetry or advertising in the included landing page. gaze is not
affiliated with Jellyfin, Spotify, YouTube, or Cloudflare. This repository does
not include or grant rights to anyone’s music. No open-source license has been
selected yet; dependencies retain their own licenses.

For contributions and architectural boundaries, read [AGENTS.md](AGENTS.md).
