# gaze

gaze is a desktop-first music client targeting Linux, Windows, and macOS. Linux on Nobara is the active development and testing platform. gaze will connect to a Jellyfin music library hosted on an Unraid server. The product name is always displayed in lowercase.

The Flutter desktop foundation, media-kit playback boundary, and secure Jellyfin connection flow are established. Authentication, session restoration, Albums browsing, authenticated direct playback, the functional player bar, temporary album queue, and Jellyfin activity reporting have been manually verified against the intended Jellyfin server on Linux. A versioned SQLite layer now saves the queue and recent playback position without storing credentials or stream URLs; restart restoration awaits manual Linux validation. Persistent bounded caching for artwork, metadata, and future lyrics remains a separate storage phase rather than an unbounded cache. Windows and macOS runner files are generated but have not been built or run on those operating systems.

## Verified development status

- **Linux:** Flutter environment verified; dependency resolution, formatting, static analysis, widget tests, and debug build pass. The application process starts with `flutter run -d linux`; the automated execution environment did not expose the graphical window for visual confirmation.
- **Windows:** runner and build files generated; build and launch validation pending on Windows.
- **macOS:** runner and build files generated; build and launch validation pending on macOS.
- **Android, iOS, and web:** outside the current project scope and not generated.
- **Dependencies:** the playback spike selected `media_kit` and `media_kit_libs_audio`; `file_picker` supports the disposable local-file test.
- **Persistence:** `sqlite3` bundles SQLite for Linux, Windows, and macOS, while Flutter's official `path_provider` selects the correct application-support directory. Queue restoration uses versioned SQLite state; authenticated artwork uses a bounded, version-aware disk cache; and Albums uses server/user-scoped metadata snapshots with explicit stale-data feedback. No additional Linux system package is required for this layer. Windows and macOS execution remain untested.
- **Jellyfin:** HTTP and HTTPS authentication works on Linux. Tokens and minimum resume information use the OS credential store; passwords are not persisted. Recently added albums, authenticated artwork, saved-session restoration, direct playback, and server activity reporting are manually verified on Linux.

The isolated playback spike selected `media_kit` 1.2.6 with `media_kit_libs_audio` 1.0.7 and uses `file_picker` 11.0.2 only for the disposable local-file test. With Fedora/Nobara's `mpv-libs` runtime installed, the backend initializes and local play, pause, resume, seeking, volume, and stop were manually verified on Linux. Authenticated remote playback is deferred to Jellyfin integration. Gapless playback, track completion, long-session stability, Windows, and macOS remain untested. See [docs/PLAYBACK_SPIKE.md](docs/PLAYBACK_SPIKE.md) for the full decision record.

## Product direction

gaze will pair artwork-focused polish and purposeful motion with familiar, understandable music organization. It is designed for desktop monitors, mouse, keyboard, and touch displays, with useful density and optional secondary panels at wide widths. It should neither copy Apple Music or Spotify nor behave like an enlarged mobile app.

See [DESIGN_DIRECTION.md](DESIGN_DIRECTION.md) for the visual and interaction principles and [PROJECT_PLAN.md](PROJECT_PLAN.md) for the staged implementation plan.

## Recommended architecture

Flutter is the selected desktop UI framework, with its Linux build path now proven for the basic shell. Its rendering model, animation tools, custom layout support, accessibility APIs, and ability to share pure Dart packages fit an artwork-led interface well. The next technical gate is a playback spike that evaluates maintained options for Linux, Windows, and macOS. Flutter also leaves a practical route to a separately designed mobile application.

When implementation begins, use a small workspace with boundaries like these:

```text
apps/
  gaze_desktop/       Flutter desktop UI and platform composition
  gaze_mobile/        possible future app; not created now
packages/
  gaze_domain/        pure Dart entities and rules
  gaze_application/   use cases and state coordination
  gaze_jellyfin/      Jellyfin HTTP, DTOs, authentication, mapping
  gaze_playback/      engine-neutral playback and queue contracts
  gaze_storage/       SQLite persistence and cache implementations
  gaze_integrations/  MPRIS and later DeskStrip adapters
```

This is a dependency direction, not a requirement to create many empty packages. Add a package only when there is real code to own. The desktop app composes the parts; shared packages do not import the desktop app.

### Component choices

- **Desktop UI:** Flutter widgets and desktop window behavior live in `gaze_desktop`. Centralized design tokens and reusable desktop components keep pages consistent.
- **Application logic:** framework-independent Dart use cases coordinate repositories, playback, queues, and observable state. A future mobile shell can reuse this layer.
- **Jellyfin:** use Jellyfin's HTTP API behind a narrow client and repository interface. Keep wire-format DTOs private to the adapter and map them into stable gaze models. Add a large third-party Jellyfin SDK only if a spike shows a clear maintenance advantage.
- **Playback:** define an engine-neutral controller after the feasibility spike. The spike must compare maintained Flutter media options for Linux, Windows, and macOS, with functional testing beginning on Nobara. The eventual adapter owns Jellyfin stream URLs and engine events; the rest of gaze sees playback state and commands.
- **Queue persistence:** keep the live queue in the application layer and persist versioned snapshots and current position transactionally in SQLite. Restore through validation so missing library items do not corrupt startup.
- **Metadata and artwork:** store normalized metadata and sync markers in SQLite. Store image files in a bounded disk cache keyed by server, item, image tag, and requested size; keep only a small decoded-memory cache. Credentials never belong in either cache.
- **Platform media sessions:** implement Linux MPRIS, Windows media-session support, and macOS Now Playing as separate adapters over a common playback controller. No platform adapter may control the media engine directly or leak into shared domain logic.
- **DeskStrip:** reserve a separate, optional integration adapter with a versioned protocol and capability negotiation. It observes the same playback state as MPRIS and remains removable without affecting the player.
- **Mobile later:** build a separate Flutter application and mobile-native UI. Reuse domain, application, Jellyfin, and appropriate persistence/playback contracts; do not reuse desktop navigation or window layouts.

## Why Flutter

Flutter is the strongest practical default for this particular product because custom artwork presentation, consistent animations, adaptive desktop composition, and later Dart reuse matter more than using native KDE widgets. It offers a much faster path for a beginner than building and maintaining a custom C++/Qt media application, while retaining strong control over visual identity.

Qt/QML would be the main alternative. It offers excellent Linux and KDE integration and mature native multimedia options, but adds C++/QML complexity, a steeper packaging and debugging burden, and no equally direct path to sharing an application core with a later Flutter-style mobile client. Tauri or Electron can create polished interfaces with web skills, but introduce web/runtime boundaries; Electron is comparatively heavy, and both still require careful native media and MPRIS integration. GTK/libadwaita is a good GNOME-native choice but is less aligned with Nobara KDE and this highly custom cross-device direction.

Flutter's principal uncertainty is not the interface: it is dependable Linux audio playback and packaging. That is why playback is a measured spike before building the full player. If the spike reveals unacceptable format, gapless, streaming, or runtime-dependency problems, Qt/QML should be reconsidered before substantial UI investment.

## Testing gaze during development

Launch gaze on Linux from a normal Konsole with:

```bash
cd /home/user/Projects/gaze && flutter run -d linux
```

For ordinary Dart or widget changes while Flutter is still running, press `r` in that terminal to hot reload the updated code. Dependency, plugin, runner, and native changes require stopping the app with `Ctrl+C` and launching it again.

## Current tool inventory

Inspected on Nobara Linux 44 KDE, x86-64. Nothing was installed by this project setup.

Present:

- Git 2.55.0 with a healthy repository
- Flutter with Linux desktop support and a detected Linux desktop device
- Dart through the installed Flutter SDK
- Clang 22.1.8, GCC/G++ 16.1.1, CMake 4.3.0, Ninja 1.13.2, Make 4.4.1, and pkg-config 2.5.1
- GTK 3 development files 3.24.52, epoxy 1.5.10, D-Bus development files 1.16.2, and standard C++ development files
- `curl`, `ffmpeg`, `ffprobe`, `mpv`, `sqlite3`, `dbus-daemon`, and `dbus-send` command-line tools

Not found by the focused probe:

- Meson (not required for a normal Flutter Linux build)
- GTK 4 development metadata (Flutter Linux currently uses GTK 3; not required for the initial plan)
- pkg-config development modules for SQLite, libmpv, GStreamer, libsecret, and json-glib
- `playerctl` (helpful for later MPRIS manual testing, not required now)
- Mesa `libGLU` development package (whether it is required should be determined by a real Flutter diagnostic/build rather than installed speculatively)

The Flutter Linux toolchain has since been verified outside the earlier read-only inspection restriction. Windows and macOS toolchains cannot be validated from Linux and remain future checks on their respective operating systems.

## Major risks

- **Playback backend:** Jellyfin libraries may contain varied codecs and may require direct play or server transcoding. Gapless playback, seeking, buffering, and long sessions need real-server testing.
- **Native runtime packaging:** media, credential-store, and D-Bus plugins can add Nobara runtime dependencies. Choose them through spikes and document packaging early.
- **Jellyfin API behavior:** server versions, authentication expiry, image tags, pagination, favorites, and playback reporting require contract fixtures and failure handling.
- **Cache growth and invalidation:** large artwork libraries can consume disk and memory unless variants, limits, and eviction are designed explicitly.
- **Secrets:** server tokens require OS credential storage and log redaction; convenience persistence must not weaken this boundary.
- **Desktop polish scope:** animation and custom visuals can expand indefinitely. Build a tokenized system and complete one vertical slice before adding pages.
- **Integration drift:** Linux MPRIS, Windows media sessions, macOS Now Playing, and DeskStrip can diverge from in-app state if they bypass the shared playback controller.
- **Cross-platform drift:** generated runners do not prove working builds. Windows and macOS must be tested on their own operating systems before releases are claimed.

## How to begin the next session

1. Read `AGENTS.md`, `PROJECT_PLAN.md`, and `DESIGN_DIRECTION.md`.
2. Confirm `git status` is clean and review the latest checkpoint.
3. Confirm the current phase in `PROJECT_PLAN.md` and choose one small exit check.
4. Preserve the connection, playback, and library boundaries; do not place tokens in URLs, logs, fixtures, or ordinary storage.
5. Run the automated and manual UI-review workflow before checkpointing visible work. Windows and macOS execution validation remains pending.
