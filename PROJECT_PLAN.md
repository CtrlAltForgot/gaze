# gaze project plan

The plan deliberately favors small, verifiable steps. A phase begins only after the previous phase's exit check passes. Package choices named below are candidates until a focused spike confirms them.

## Phase 0 — foundation and decisions

**Goal:** establish a safe repository and prove the intended toolchain.

- **Complete on Linux:** Git health, the documentation checkpoint, Flutter environment verification, dependency resolution, formatting, analysis, widget tests, and a Linux debug build.
- **Complete on Linux:** the generated desktop shell starts under `flutter run -d linux`; visual confirmation was unavailable in the automated execution environment.
- **Generated, validation pending:** Windows runner and build configuration. Validate on Windows before claiming support is tested.
- **Generated, validation pending:** macOS runner and build configuration. Validate on macOS before claiming support is tested.
- Record architecture decisions for playback, local persistence, credential storage, and state management.
- Keep future dependencies conditional on maintained Linux, Windows, and macOS support or a documented platform adapter strategy.

**Exit check:** complete for the active Linux environment. The neutral generated shell resolves dependencies, formats, analyzes, tests, builds in debug mode, and starts. Windows and macOS build validation remain explicit future tasks on their respective operating systems.

## Phase 1 — cross-platform playback feasibility spike

**Goal:** prove that Flutter has a practical playback path for Linux, Windows, and macOS before investing in the real interface or player architecture. Execute functional tests on Linux first and do not describe Windows or macOS behavior as tested until it is exercised on those systems.

**Current status:** complete for the desktop playback foundation. `media_kit` initializes successfully on Linux with the installed `mpv-libs` runtime. A user-selected local music file passed manual play, pause, resume, forward/backward seek, volume, and stop checks. Authenticated remote playback is deferred until Jellyfin authentication and stream URL generation are implemented. Gapless behavior, track completion, long-session stability, Windows, and macOS remain future validation tasks.

- Build a minimal, disposable test screen inside the generated application; it is test tooling, not the gaze interface.
- Compare the most practical maintained Flutter playback options, considering project activity, Linux, Windows, and macOS support, API fit, packaging, licensing, and native runtime requirements.
- Test a local audio file first. Defer remote testing to authenticated Jellyfin direct-play and transcoded URLs once authentication and stream URL generation exist.
- Verify play, pause, seek, volume, and stop for the selected backend. Carry track-completion and detailed error-path validation into later playback work.
- Test consecutive compatible tracks and document whether true or acceptably seamless gapless playback appears feasible; do not claim gapless support from API documentation alone.
- Record every required native build and runtime dependency for Linux, Windows, and macOS and whether it is bundled. Distinguish documentation research from dependencies actually verified on Nobara.
- Remove the disposable screen after the decision is documented, or keep it isolated from production code until the real playback adapter is implemented.
- Do not create the real queue, persistent player bar, Now Playing interface, Jellyfin client, or final playback architecture during this spike.

**Exit check:** complete for foundation selection. The decision record names the candidates and versions, stated desktop-platform support, Linux commands and local media behavior actually tested, platform-specific native dependencies, limitations, and the recommended backend. Authenticated Jellyfin streaming, gapless behavior, long-session stability, track completion, and Windows/macOS execution remain clearly documented later checks.

## Phase 2 — desktop design foundation

**Goal:** create the original gaze visual system and application shell without server or playback complexity.

- Define color, typography, spacing, shape, elevation, motion, and focus tokens.
- Build the desktop window shell, navigation, content area, and persistent player-bar layout using sample in-memory models.
- Define wide, medium, and compact desktop behavior, including an optional queue region.
- Add keyboard focus, screen-reader labels, touch targets, and reduced-motion behavior.
- Build a small visual gallery for reusable controls and artwork treatments.

**Exit check:** widget tests pass and the shell is reviewed at representative desktop widths, keyboard-only, touch-sized, light/dark where supported, and reduced motion.

## Phase 3 — reusable domain and application core

**Goal:** model music behavior without Flutter, Jellyfin, or a database.

- Add domain entities for artists, albums, tracks, playlists, library identifiers, and playback items.
- Define repository, playback, queue, and cache interfaces.
- Implement small use cases such as loading a home section and changing favorites against fakes.
- Define immutable playback and queue state plus deterministic queue operations.

**Exit check:** pure Dart unit tests cover domain rules and shared packages import no desktop or Flutter APIs.

## Phase 4 — Jellyfin connection and read-only library

**Goal:** authenticate safely and browse a real Jellyfin music library.

- Implement Jellyfin HTTP transport, authentication, pagination, error mapping, and DTO-to-domain mapping.
- Store the access token through an OS credential-store adapter; keep server configuration separately.
- Add connection setup, recently added, albums, artists, and basic search one slice at a time.
- Handle unreachable servers, expired sessions, malformed responses, empty libraries, and cancellation.

**Exit check:** contract tests use sanitized fixtures, unit tests use a fake transport, and a documented manual test can browse the intended server without exposing credentials.

## Phase 5 — playback adapter and basic player

**Goal:** integrate the backend selected by the early spike behind a maintainable playback boundary.

- Reconfirm the selected backend against authenticated Jellyfin direct-play and transcoded URLs without persisting credentials in diagnostics.
- Verify error recovery and representative library formats beyond the feasibility cases.
- Implement the engine-neutral playback contract and its selected backend adapter, then connect it to the persistent player bar.
- Report playback progress and stop events to Jellyfin.

**Exit check:** automated controller tests pass and documented manual tests play, seek, pause, resume, advance, and recover from a network failure.

## Phase 6 — durable queue and caches

**Goal:** resume reliably and stay responsive with a larger library.

- Choose and migrate a local SQLite schema for queue, playback position, preferences, and indexed metadata.
- Persist queue edits atomically and restore conservatively after an unclean exit.
- Add bounded artwork disk caching with size variants, validation, eviction, and cleanup.
- Define offline and stale-data behavior; do not imply that uncached tracks are playable offline.

**Exit check:** migration, restart, corrupt-state, eviction, and cache-key tests pass.

## Phase 7 — deeper desktop experience

**Goal:** expand complete desktop workflows without losing consistency.

- Add album, artist, track, playlist, favorites, and search pages incrementally.
- Add expandable Now Playing and an optional right queue panel.
- Add drag-and-drop queue editing, context menus, keyboard shortcuts, and polished transitions.
- Derive restrained backgrounds from artwork with contrast safeguards and cached results.
- Add synchronized lyrics only after source support and timing behavior are documented.

**Exit check:** each workflow has widget tests, keyboard coverage, defined loading/error/empty states, and a visual review against `DESIGN_DIRECTION.md`.

## Phase 8 — desktop platform integrations

**Goal:** behave like a well-integrated application on each supported desktop platform without leaking platform behavior into shared application logic.

- Implement MPRIS as a D-Bus adapter over the shared playback controller.
- Validate metadata, position, seek, transport controls, and desktop media-key behavior.
- Implement Windows media-session support as a separate adapter over the same playback controller and validate it on Windows.
- Implement macOS Now Playing support as a separate adapter over the same playback controller and validate it on macOS.
- Specify the DeskStrip protocol with versioning, capability discovery, and reconnect behavior.
- Implement DeskStrip in a separate adapter without coupling it to widgets or the media engine.

**Exit check:** each platform adapter passes validation on its own operating system. D-Bus inspection and `playerctl`-style compatibility tests pass on Linux where tooling is available; DeskStrip can be disabled without changing playback behavior.

## Phase 9 — reliability and packaging

**Goal:** make gaze safe to distribute and update.

- Profile startup, scrolling, artwork memory use, and long playback sessions.
- Harden logging, redaction, crash recovery, and database migrations.
- Add reproducible Nobara packaging and document runtime dependencies.
- Test upgrade, uninstall, configuration retention, and a clean-machine install.

**Exit check:** a versioned artifact passes the release checklist on a clean supported Nobara environment.

## Later — separate mobile application

Create a separate mobile application shell that consumes the stable domain, application, and Jellyfin packages. Give it a mobile-native information architecture rather than reusing desktop screens. Share behavior and data contracts; share UI only when a component is genuinely appropriate on both form factors.
