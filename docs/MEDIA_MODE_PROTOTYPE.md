# Media Mode prototype

The player artwork reveals an up-chevron on hover or keyboard focus. It opens
Media Mode in the existing window, with large artwork on the left and playback
on the right. Escape or the down-chevron returns to the retained library page.
The normal player is 88 pixels high; its transport is slightly smaller. Media
Mode uses the same playback and queue controllers, so modes and queue position
remain shared with MPRIS and the normal player.

Overflowing player titles pause for five seconds, scroll at 28 pixels/second,
then wrap seamlessly to the original starting position and pause again. Library
rows and sidebar names animate only on hover, avoiding an entire library of
active tickers. Short text stays static. Reduced motion and hidden views stop
marquees. Window corners use a 10-pixel clip with a transparent GTK surface;
maximized windows stay square.

Normal browsing has a still artwork-derived background. Media Mode can enable
slow movement, capped at 20 paint requests per second, with no blur or particle
system. It uses a separate repaint boundary and pauses when hidden. The sun-like
motion control switches it off. This is a low-cost design, not a promise of zero
CPU/GPU use on every device.

## Local catalog and lyrics

The existing local song catalog holds the library in SQLite and can render
before its network refresh. Playlist tracks now also have account-scoped,
complete local snapshots. Cached order and duplicate entry IDs are preserved;
background refresh does not replace the complete list with partial pages.
Cached playlists can play while metadata refresh continues. Refresh requests
use 500-song pages instead of 100, reducing sequential requests.

The content cache is bounded to 512 records / 64 MiB and contains no credentials
or stream URLs. Only complete snapshots replace earlier data. Lyrics support an
independent provider interface with an active LRCLIB adapter and local cache.
The user authorized sending title, artist, and duration on October 20, 2026.
Lookups occur when the lyrics panel opens, after the library has no lyrics. There is no Spotify session extraction. Tests use fake
HTTP responses. Failed or missing lyrics remain a distinct empty/error state.

## Direction for gaze-owned infrastructure

The project already has a gaze service for imports and account workflows.
The next server slice should make it the catalog authority: stable gaze song
IDs, an indexed library, a versioned change feed, artwork and lyrics endpoints,
and streaming adapters. The desktop should retain its own queryable catalog
and apply small deltas in the background. Jellyfin can remain one ingestion and
streaming adapter while the UI depends on gaze contracts. Replacing the whole
server is a separate migration: preserve playlists, duplicate/order semantics,
account permissions, listening history, and rollback before switching authority.
This prototype adds durable local playlist caching; it does not claim that the
server migration has been implemented or deployed.

## Linux refresh rate

The optional release engine is pinned to Flutter 3.44.7 engine revision
`69c8c61792f04cc809dfef0c910414fb9afc06cd`. The matching source patch is in
`packaging/linux/flutter-3.44.7-high-refresh.patch`. The local binary lives in
ignored `.local-engine/libflutter_linux_gtk.so`; CMake verifies SDK revision and
SHA-256 before packaging it. Debug builds use the standard debug engine.
A normal release rebuild preserves this engine while the local file is present.
To roll back, remove that optional directory and rebuild. The global SDK is
never modified. The runner prefers native Wayland when available, even when a parent launcher
inherited GDK_BACKEND=x11. Set GAZE_DISPLAY_BACKEND=x11 for an explicit
compatibility override. The X11 compositor may still limit cadence.

Acceptance: measure actual frame cadence in gaze, exercise scroll and native
window dragging, inspect corner transparency, open/close Media Mode, test
narrow/wide layouts, marquee pause/wrap/reduced motion, cached refresh failure,
account changes, and missing/synchronized lyrics. Automated evidence, native
visual inspection, and user approval are separate checks. Only Linux has been
built and run; other desktop platforms are unverified.
