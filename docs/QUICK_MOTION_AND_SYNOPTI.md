# Quick motion and Synopti source recovery

October 20, 2026 prototype. Visual acceptance remains pending user review.

## Motion contract

Common feedback is 110 ms, opening is 180 ms, and closing is 130 ms, using cubic easing. Playback and other commands run immediately. Reduced-motion preferences remove spatial transitions and waits. No animation requires a new dependency or a continuous full-window blur.

Retained library, Connect and Media Mode pages fade and shift by 12 pixels. Hidden pages stop ticking and cannot take input. Library scroll positions survive main navigation. Media Mode restores Escape focus on reopening. Queue/lyrics panels retain their content while closing, and reverse the same controller if toggled during a transition. Album, artist and playlist detail changes crossfade; playlist collection and detail views use separate scroll controllers. Outgoing playlist rows capture their data to remain valid if the playlist is deleted during exit.

Player hover/press feedback, play/pause, shuffle/repeat markers, row selection and hover controls, artwork changes, menus and dialogs share short transitions. Sliders retain direct pointer tracking. Ambient movement remains optional and separate from these finite interactions.

## Synopti source authority

A validated YouTube URL from a played-song event is already the chosen recording. Missing artist metadata must never require a second source match. New known-source events enter the normal import queue and bypass search. Invalid or absent source URLs remain actionable.

Recovery only releases existing Synopti jobs for the enabled linked account that have the exact legacy missing-artist error, `needsMatch`, `unidentified`, a valid source URL, no saved file, and no manual match. Excluded URLs remain excluded. Ready, failed, manually selected and other-account work is unchanged. Recovery is durable and idempotent.

The existing downloader metadata response can improve unknown credits, preferring structured artist/track fields, then the artist/title separator in the original video title. The original title and job ID are retained. Uploader/channel names are never assumed to be artist credits. Missing credits alone never block the exact recording. Source quality and stream-copy verification are unchanged.

The server update is an overlay of only worker.js, audio.js and the new synopti-source.js on the exact running image. The previous container/image and a private pre-update state snapshot are retained for rollback. It does not require restarting Synopti or changing its feed.

## Verification and delivery

The service update was explicitly approved and deployed as `gaze-service:synopti-source-20261020-v1`. All 65 legacy artist blocks were released with their source links retained. Import completion is asynchronous; queue recovery is not a claim that all downloads have finished. All 68 service tests passed locally and inside the deployed image. The old container is stopped and retained as `gaze-service-before-synopti-source-20261020`. Host configuration and environment were preserved.

Desktop analysis, 191 Flutter tests, and Linux debug/release builds pass. The release review covered Media Mode, lyrics, the queue, playlist details and scrolling. A 461-interval scrolling sample had a 6.067 ms median cadence, with 1.727 ms build and 1.366 ms raster 95th-percentile durations. This is a measurement on this Linux setup, not a guarantee for every system or every frame. The normal release excludes all review harness controls. Manual acceptance and Windows/macOS testing remain pending.
