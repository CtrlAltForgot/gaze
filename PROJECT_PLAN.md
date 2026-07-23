# gaze project plan

The plan deliberately favors small, verifiable steps. A phase begins only after the previous phase's exit check passes. Package choices named below are candidates until a focused spike confirms them.

## Product outcome

gaze should bring personally owned music libraries back to life through a premium, artwork-led desktop experience. Apple Music sets the quality bar for beauty, animation, and presentation; Spotify provides a reference for familiar, intuitive organization. gaze must interpret those qualities through an original interface built around the listener's own Jellyfin-hosted library rather than copying either service.

The experience should make albums feel valuable, browsing feel effortless, and local ownership feel as polished and convenient as a commercial streaming service. Server and playback complexity must remain behind the interface so the listener experiences music, artwork, and clear choices rather than infrastructure.

## Current position and next milestones

- **Complete:** repository and Flutter desktop foundation on Linux.
- **Complete:** generated Linux, Windows, and macOS runners; Windows and macOS validation remains pending on their respective operating systems.
- **Complete:** Linux playback foundation selection and local media controls using media-kit.
- **Complete for initial direction:** Phase 2's first desktop shell received manual visual approval; deeper UI work is paused until real library data is available.
- **Complete on Linux:** platform-neutral connection models, Jellyfin transport, OS-backed token storage, authentication, session restoration, and the first real Home library slice.
- **Complete:** secure token persistence and real-server authentication manually verified on Linux.
- **Complete:** the first read-only Jellyfin music-library slice displays real recently added albums and authenticated artwork on Home and received manual visual approval on Linux.
- **Complete on Linux:** saved-session restoration validates the stored token and automatically reloads Home after restart; the user manually verified the restart sequence.
- **Complete on Linux:** Albums navigation, server-side sorting, automatic bounded pagination, and read-only album track listings passed real-library visual and interaction review. Login persistence was hardened after real keyring feedback, and the non-secret server/username profile remains available for reconnection.
- **Complete on Linux:** authenticated direct play, track selection, the functional player bar, fast hover/focus play actions, and a temporary album queue with previous, next, and completion advancement passed manual playback and visual review.
- **Complete on Linux:** Jellyfin playback start, throttled progress, pause, completion, track-change, and stop reporting are implemented without coupling server calls to widgets or media-kit. The user confirmed that gaze playback appears in the real Jellyfin server activity view.
- **Active:** Phase 6 now has a versioned SQLite foundation and conservative queue/playback restoration awaiting manual restart validation on Linux. Artwork and metadata caching remain separate later slices.

Do not skip directly to a complete Home page or full Jellyfin client. Each milestone should produce one understandable, testable slice.

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

**Current status:** in progress. The responsive desktop shell and real library views now use a manually approved artwork-derived atmosphere: the current album supplies a contrast-fitted accent and a continuous ambient palette beneath translucent navigation and player surfaces, with a reduced-motion fallback. This confirms the direction, not the finished design. Broader width review, keyboard traversal, focus behavior, touch sizing, and component refinement remain.

- Document and implement the first color, typography, spacing, shape, elevation, motion, and focus tokens without treating them as final branding.
- Replace the disposable playback test as the default route with a basic desktop shell while keeping the diagnostic screen isolated and reachable during development.
- Build only the structural regions needed to review desktop composition: navigation, main content, and a nonfunctional player-bar placeholder using in-memory sample content.
- Define wide, medium, and compact desktop behavior. Reserve space conceptually for a future optional queue region without implementing the queue.
- Add keyboard focus, screen-reader labels, touch targets, and reduced-motion behavior.
- Review the shell for artwork emphasis, information density, intuitive hierarchy, and originality against `DESIGN_DIRECTION.md`.
- Run the complete visual-testing workflow in `AGENTS.md` and obtain manual approval before committing each meaningful visible step.

**Exit check:** automated checks pass and the user manually approves the shell at representative desktop widths. Keyboard traversal, touch-sized targets, focus visibility, and reduced-motion behavior are reviewed. No server connection or working production player is required.

## Phase 3 — reusable domain and application core

**Goal:** model music behavior without Flutter, Jellyfin, or a database.

**Current status:** active in a deliberately narrow form. Add only the server, session, and music-library contracts required by the first Jellyfin connection slice; broader queue and library behavior remains later work.

- Add domain entities for artists, albums, tracks, playlists, library identifiers, and playback items.
- Define repository, playback, queue, and cache interfaces.
- Implement small use cases such as loading a home section and changing favorites against fakes.
- Define immutable playback and queue state plus deterministic queue operations.
- Keep these models independent of Flutter widgets, media-kit, HTTP, databases, and Jellyfin response formats so a future mobile client can reuse them.

**Exit check:** pure Dart unit tests cover domain rules and shared packages import no desktop or Flutter APIs.

## Phase 4 — Jellyfin connection and read-only library

**Goal:** authenticate safely and browse a real Jellyfin music library.

**Current status:** active. The tested transport foundation accepts `http://` and `https://` addresses, preserves optional Jellyfin base paths, probes public server information, and parses username/password authentication behind an injectable interface. The temporary connection screen never saves the password; it stores the returned access token and stable installation device ID through the operating system credential store. Plain HTTP is supported for the user's trusted local network and documented as unencrypted. No real address or credential has entered the repository. The user manually verified authentication against the intended Jellyfin server on Linux. gaze now requests recently added music albums, maps them to a platform-neutral model, and fetches artwork with authenticated headers rather than token-bearing URLs. Automated coverage is complete; real-library content and visual behavior still require manual approval. Saved-session restoration, pagination, and broader library pages remain later focused slices.

- Confirm the Jellyfin server/API version and connection expectations without recording a private address, username, or token in the repository.
- Use the maintained `package:http` client behind an injectable transport boundary on Linux, Windows, and macOS.
- Use `flutter_secure_storage` for access tokens and the installation device ID. Its Linux `libsecret-devel` build requirement is installed; never store the account password.
- Implement Jellyfin HTTP transport, authentication, session expiry, pagination, error mapping, and DTO-to-domain mapping behind repository interfaces.
- Store the access token through an OS credential-store adapter; keep the non-secret server configuration separately.
- Create sanitized response fixtures containing no personal server, account, or library information.
- Add connection setup and one read-only library slice first, preferably recently added albums. Add broader album, artist, and search capabilities only in later focused tasks.
- Expand Albums as the first complete read-only browse workflow: load bounded pages, sort on the server, and request tracks only when an album is opened.
- Handle unreachable servers, expired sessions, malformed responses, empty libraries, and cancellation.
- After browsing and playback are stable, add a separate library-maintenance phase for safe playlist management and metadata correction. Preview changes, distinguish deleting a Jellyfin playlist from deleting media files, and require explicit confirmation for destructive operations.

**Exit check:** contract tests use sanitized fixtures, unit tests use a fake transport, secrets are absent from Git and logs, and a documented manual test can authenticate and browse the first read-only library slice on the intended server.

## Later library maintenance — metadata and playlist repair

**Goal:** help listeners repair imperfect owned libraries without requiring a destructive rebuild.

- Surface missing artwork, unknown artists, suspicious album grouping, and incomplete tags.
- Edit supported Jellyfin metadata through a reviewed adapter, with before/after previews and clear server-side effects.
- Create, rename, edit, and delete Jellyfin playlist objects separately from media-file operations.
- Never infer that an imported playlist folder is an album correction without user review.
- Treat deleting media files as a distinct high-risk action requiring explicit confirmation and a documented recovery expectation.
- Consider external tag-writing or identification tools only through a focused design and safety review; do not silently rewrite the user's source files.

**Exit check:** sanitized tests cover previews, permission errors, partial failures, and destructive-action confirmation; the user manually verifies changes against a backed-up test subset before broader use.

## Phase 5 — playback adapter and basic player

**Goal:** integrate the backend selected by the early spike behind a maintainable playback boundary.

**Current status:** complete for the initial Linux slice. Direct playback is manually verified on Linux. gaze generates a static Jellyfin audio stream URL while keeping the access token exclusively in the authorization header. media-kit accepts the URL and headers through the engine-neutral playback source. Album track rows start playback, and the persistent bar exposes play/pause, seek, volume, position, duration, current metadata, artwork, and visible errors. A temporary album queue enables previous, next, and completion advancement without persistence. A separate application-level reporter sends start, throttled progress, pause, completion, track-change, and stop events to Jellyfin, and the user confirmed that gaze playback appears in the real server activity view. Durable queue editing, playback-state restoration, and fallback transcoding remain later work.

- Generate authenticated Jellyfin direct-play and transcoded URLs inside the Jellyfin adapter without persisting credentials or private URLs in diagnostics.
- Reconfirm the selected backend against those real Jellyfin sources; generic public remote-URL testing is not required.
- Verify error recovery and representative library formats beyond the feasibility cases.
- Implement the engine-neutral playback contract and its selected backend adapter, then connect it to the persistent player bar.
- Report playback progress and stop events to Jellyfin.

**Exit check:** automated controller tests pass and documented manual tests play, seek, pause, resume, advance, and recover from a network failure.

## Phase 6 — durable queue and caches

**Goal:** resume reliably and stay responsive with a larger library.

**Current status:** queue and playback restoration use versioned SQLite. A separate versioned artwork directory caches authenticated Jellyfin images under server, item, image-tag, and size keys, bounded to 256 MiB and 2,000 entries with least-recently-used eviction. Albums reads atomic metadata snapshots scoped by server, user, sort, offset, and limit. Snapshots younger than 15 minutes load immediately with matching disk-cached artwork; expired snapshots refresh from Jellyfin and become an explicitly labeled, timestamped fallback if that request fails. Artwork-derived accent and ambient colors are stored as five ARGB values under a content fingerprint, avoiding repeat image decoding after restart while naturally invalidating changed artwork. Cold-start browsing without a validated Jellyfin session and future lyrics caching remain later work.

- Choose and migrate a local SQLite schema for queue, playback position, preferences, and indexed metadata.
- Persist queue edits atomically and restore conservatively after an unclean exit.
- Add bounded artwork disk caching with size variants, validation, eviction, and cleanup.
- Cache metadata and future synchronized lyrics with server-scoped keys, refresh markers, schema migrations, and explicit size/age policies. A cache must accelerate Jellyfin, never become the only copy of user data.
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
