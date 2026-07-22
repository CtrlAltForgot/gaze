# gaze playback feasibility spike

## Status

**Desktop playback foundation validated on Linux.** The media-kit backend initializes successfully with the installed `mpv-libs` runtime. User-selected local music playback was manually verified for play, pause, resume, forward and backward seeking, volume changes, and stop. Authenticated Jellyfin streaming is deferred until Jellyfin authentication and stream URL generation exist. Gapless transitions, track-completion behavior, long-session stability, Windows, and macOS still require later validation.

Research was reviewed on 2026-07-22. Package capabilities below come from current official package pages, API documentation, repositories, and backend documentation. A documented capability is not described as tested unless it was exercised during this spike.

## Decision summary

Use `media_kit` with its audio-only native library package for the disposable spike. It is the strongest technical fit because it uses a largely shared libmpv-backed implementation across Linux, Windows, and macOS and directly exposes the playback, playlist, event, HTTP-header, and error primitives a desktop music player needs.

gaze accesses media-kit through a small `PlaybackController` interface so the backend remains replaceable. The local Linux results are sufficient to adopt it as the desktop playback foundation. Gapless behavior, longer listening sessions, authenticated Jellyfin streams, and Windows/macOS builds and runtime behavior remain later validation gates.

Use `file_picker` only for the disposable local-file chooser. Its official compatibility table includes Linux, Windows, and macOS. It is kept out of the playback interface so a future UI or platform policy can replace it independently.

## Candidates compared

| Area | `media_kit` 1.2.6 | `just_audio` 0.10.6 plus desktop backend | `audioplayers` 6.8.1 | `flutter_soloud` 4.0.13 |
| --- | --- | --- | --- | --- |
| Desktop platforms | Official package lists Linux, Windows, and macOS | Core package lists all three, but Linux and Windows require an additional implementation such as `just_audio_media_kit` | Official federated package lists all three | Lists desktop support, but describes itself as a low-level game/immersive-audio engine |
| Local and HTTP(S) sources | `Media` accepts file paths and URLs; HTTP headers are supported | File, URL, byte stream, and headers are documented across desktop backends | Device files and URL sources are documented | Local and streamed audio are supported, with a narrower music-format focus |
| Music formats | libmpv/FFmpeg backend provides broad codec/container coverage including FLAC, MP3, AAC, and common formats | Format support follows each platform backend; Linux/Windows through the media-kit bridge inherit libmpv | Platform-specific; Linux depends on installed GStreamer plugins, making codec availability a packaging concern | Documentation names PCM, MP3, Ogg/Opus/Vorbis, and FLAC streaming; AAC is not part of the highlighted stream list |
| Controls and observability | Play, pause, stop, seek, volume, position, duration, buffering, completion, and error streams are directly documented | Play, pause, seek, volume, duration/position, processing states, and errors are directly documented | Play/resume, pause, stop, seek, volume, position, duration, completion, and errors are available | Low-level controls are available, but the API is oriented toward voices and sound sources rather than a music transport |
| Playlist and next-track preparation | Native `Playlist` API provides next/previous/jump/shuffle and mutable queue operations; exact next-track preloading behavior needs measurement | Strong sequence API with lazy preparation and a documented gapless-playlist abstraction | One player handles one source; a serious ordered playlist and preloading policy would be application work | No high-level music-playlist model suitable for gaze was identified |
| Gapless evidence | libmpv has gapless audio modes, but gaze has not demonstrated media-kit transitions; treat as unproven | Package table claims gapless on desktop, but Linux/Windows behavior depends on the separate backend; the bridge documentation identifies limitations and requires testing | No official first-class gapless playlist guarantee was found | Advertises gapless looping, which is not the same as gapless transitions between album tracks |
| Long-session confidence | Project describes intensive media-app use and shares most native behavior across desktops; gaze still needs an actual soak test | Mature core API, but Linux/Windows add another independently maintained bridge layer | Mature and recently published, but its multi-sound/single-source emphasis is a weaker match for long-form album playback | Capable engine, but its stated primary use case does not match a conventional desktop music player |
| Native/runtime considerations | Audio-only package selects the platform support packages. On Linux, media-kit still dynamically loads a system `libmpv.so`; Windows/macOS packaging and the full transitive license audit require native validation | macOS uses its native implementation; Linux/Windows need a backend package and native libraries, increasing integration layers | Linux requires GStreamer development libraries to build and suitable runtime plugins/codecs to play formats | Bundles/builds a C++ audio engine; platform build configuration still requires validation |
| Future platform media controls | Can remain below a gaze-owned controller; MPRIS/SMTC/Now Playing can observe that controller later | Same architectural possibility; `audio_service` is related but does not remove desktop-backend differences | Can be wrapped, but playlist/state semantics would require more gaze-owned coordination | Possible to wrap, but would require more translation from low-level voices to music-player state |
| Jellyfin suitability | URL playback, headers, buffering state, broad codecs, and playlists are a strong direct-play/transcode fit | URL/header support is strong, but the desktop bridge ultimately uses media-kit on Linux/Windows | URL playback works, but GStreamer codec/runtime variability and lack of playlist semantics add risk | Remote streams are possible, but the music transport and format story is weaker |
| License | Package is MIT; libmpv/FFmpeg binary composition must be audited before distribution | `just_audio` is MIT; `just_audio_media_kit` is Unlicense and depends on MIT media-kit, with the same native binary audit | MIT | MIT according to its package metadata; underlying native notices still require packaging review |
| Maintenance signal | Current stable package and native library releases are published by `media-kit.dev`; repository has ongoing fixes and releases | Core package is very active; the currently documented media-kit bridge release is older and from an unverified uploader | Recently published and actively maintained | Very recently published and active |

Download counts were not used as a selection criterion.

## Why `media_kit` is preferred

`just_audio` is the closest competing API because it explicitly models gapless music playlists. On macOS it uses a native implementation, while Linux and Windows need a separate package. The most practical bridge, `just_audio_media_kit`, wraps the same media-kit engine being considered directly and adds another ownership and compatibility boundary. Its package page also notes incomplete shuffle behavior and limited multiple-player testing. Using media-kit directly is simpler for this desktop-only spike and gives gaze direct access to backend logs, errors, buffering, audio parameters, and playlists.

`audioplayers` is a good general audio plugin and is actively maintained, but its documented model is one source per player and multiple simultaneous players. That is an excellent fit for effects and independent sounds, not as strong a fit for ordered albums, gapless transitions, and next-track preparation. Its Linux implementation also relies on system GStreamer components and codec plugins.

`flutter_soloud` is deliberately low-level and primarily designed for games and immersive audio. Its low latency and sound-processing capabilities are valuable, but gaze would have to build more music-player semantics itself, and the documented streamed-format list is less reassuring for Jellyfin libraries containing AAC-based media.

## Proposed spike dependencies

- `media_kit` — playback API and event streams
- `media_kit_libs_audio` — audio-only native libraries for the supported platforms
- `file_picker` — disposable local-file selection on Linux, Windows, and macOS

No state-management, HTTP-client, queue, Jellyfin, media-session, or UI component package is proposed.

## Native and packaging considerations

- `media_kit_libs_audio` aggregates the audio support packages for Linux, Windows, and macOS. It resolved to 1.0.7, with `media_kit_libs_linux` 1.2.1, `media_kit_libs_windows_audio` 1.0.9, and `media_kit_libs_macos_audio` 1.1.4.
- On Linux, `media_kit_libs_linux` does not bundle libmpv. media-kit searches for `libmpv.so`, `libmpv.so.2`, or `libmpv.so.1` at runtime.
- Fedora 44's `mpv-libs` 0.41.0-5.fc44 package is installed and provides `/lib64/libmpv.so.2`. After installation, the media-kit backend initialized successfully.
- media-kit uses libmpv, which in turn uses FFmpeg and platform audio/output libraries. The Dart packages are MIT, but distribution must retain required notices and audit the exact libmpv/FFmpeg build configuration for LGPL/GPL implications before release packaging.
- Windows and macOS native libraries may be generated by Flutter dependency resolution, but that does not prove they compile or run. Each must later be built, played, sought, stopped, and exercised through completion on its own operating system.
- The file picker supports the three desktop platforms. On macOS, sandboxed distribution will need the user-selected read entitlement documented by the package. Linux desktop dialogs depend on the available portal/dialog tooling; the current KDE environment must be exercised manually.
- No additional system package or `sudo` action is authorized by this spike. If the Linux build reports a missing native library, stop and document the exact package before requesting approval.

## Automated verification

| Command | Result |
| --- | --- |
| `flutter pub get` | Passed. Seven transitive packages reported newer versions outside current constraints; dependency resolution succeeded. |
| `dart format .` | Passed. Five Dart files formatted; the final run required no changes. |
| `flutter analyze` | Passed with no issues. |
| `flutter test` | Passed: one widget test exercises the diagnostic screen through a fake playback controller. |
| `flutter build linux --debug` | Passed; produced `build/linux/x64/debug/bundle/gaze`. |
| `flutter run -d linux` | Passed initialization after `mpv-libs` was installed. The media-kit Linux plugin registered and its native backend allocated successfully. |

The run also emitted a cursor-theme warning. That warning is unrelated to playback, but should be rechecked after the native dependency is available.

## Required Linux manual test record

Remote playback will be tested through the real Jellyfin integration after authentication and stream URL generation are implemented. The generic remote URL path was intentionally not exercised further because authenticated Jellyfin playback is the actual product requirement.

| Test | Result | Notes |
| --- | --- | --- |
| Select and load a local music file | Passed | Manually verified on Linux with a user-selected file. |
| Play local file and observe playback | Passed | Manually verified on Linux. |
| Pause and resume without restarting | Passed | Manually verified on Linux. |
| Seek forward and backward | Passed | Manually verified on Linux. |
| Change volume down and up | Passed | Manually verified on Linux. |
| Stop and confirm stopped state | Passed | Manually verified on Linux. |
| Let a track finish and observe completion | Pending | |
| Load an authenticated Jellyfin stream | Deferred | Requires Jellyfin authentication and stream URL generation. |
| Exercise controls on a Jellyfin stream | Deferred | Validate direct play and transcoding during Jellyfin integration. |
| Load an invalid source and observe a visible useful error | Pending | |
| Play two compatible album tracks consecutively and measure transition | Pending | Gapless is not claimed unless demonstrated. |
| Continue ordinary playback for an extended listening session | Pending | Record duration and any stalls, leaks, or state drift. |

## Sources

- [`media_kit` package and guide](https://pub.dev/packages/media_kit)
- [`media_kit` repository and MIT license](https://github.com/media-kit/media-kit)
- [`media_kit_libs_audio` package](https://pub.dev/packages/media_kit_libs_audio)
- [`just_audio` package and desktop feature table](https://pub.dev/packages/just_audio)
- [`just_audio_media_kit` package and limitations](https://pub.dev/packages/just_audio_media_kit)
- [`audioplayers` package](https://pub.dev/packages/audioplayers)
- [`audioplayers` official getting-started guide](https://github.com/bluefireteam/audioplayers/blob/main/getting_started.md)
- [`audioplayers_linux` setup](https://pub.dev/packages/audioplayers_linux)
- [`flutter_soloud` package](https://pub.dev/packages/flutter_soloud)
- [`file_picker` desktop compatibility](https://pub.dev/packages/file_picker)
- [mpv stable manual](https://mpv.io/manual/stable/)
- [mpv repository and platform notes](https://github.com/mpv-player/mpv)
- [Fedora 44 `mpv-libs` package](https://packages.fedoraproject.org/pkgs/mpv/mpv-libs/)
