# Synchronized lyrics and quieter playlist actions

The Playlists heading owns a white plus action, with an accessible New playlist
name and the existing creation dialog. Media Mode labels its ambient animation
switch as Background motion with its current On/Off state.

Lyrics prefer a synchronized library timeline. Plain library text does not block
an authorized LRCLIB lookup for a timed version. Exact full-credit and primary
artist lookups precede a bounded search whose results must match title, artist
and recording duration within two seconds. Real artist names containing commas
remain intact. Requests contain only public song metadata. Provider failures
preserve available plain text. Timed results cache for 30 days; plain/missing
results for six hours so an old miss does not mask newly supplied timestamps.

The player and Media Mode share one timestamp-based view and the existing seek
controller. It follows actual playback events, including backward seeks, retries
when the engine supplies the recording duration, and rejects late responses from
a previous track. Lines wrap without clipping; centering uses their measured
positions. User scrolling pauses automatic following for three seconds. Reduced
motion removes scrolling and text transitions. No word timings are fabricated.

Media Mode renders lyrics directly over the existing ambient background with no
card, duplicate header, divider or opaque line selection. Inactive lines are soft,
the current line is bright, and timed lines support pointer and keyboard seeking.
Plain lyrics explicitly say timing is unavailable and cannot seek.

Acceptance: source selection/failure/cache and recording-mismatch tests; actual
playback highlights, backward/click seeks, wrapped lines, stale responses and
late durations; compact/wide Media Mode and playlist creation regression checks.
Run full formatting, analysis, tests and Linux debug/release builds, then inspect
the running Linux app. Visual approval belongs to the user. Windows/macOS have
not been run for this change. No server update or public artist enrichment is part
of this change.

## Center lyrics and independent queue

The player lyrics button opens an unboxed center page in place of the library
browser. Its close action, player toggle and Escape return to the retained page,
including playlist details and scroll position. Sidebar navigation leaves lyrics
and opens the chosen destination. The queue has independent visibility, remains
on the right, and can be opened, closed and used while lyrics stay in the center.
With lyrics visible, even compact desktop widths keep the queue inline so it
cannot cover the lyric page. The persistent player and left navigation stay put.

Center-page transitions use the existing short page animation. Hidden lyric views
retain their state but defer new song lookups until shown again. Media Mode keeps
its existing unboxed lyric presentation and no longer changes queue visibility.
Acceptance adds simultaneous lyric/queue layout at 800, 1280 and 1800 pixels,
independent toggles, click seeking, Escape, sidebar navigation, retained playlist
scroll position and deferred lookups while hidden.
