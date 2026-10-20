# Party Sessions

Acceptance: double-click a playlist in either location starts its complete queue
using the existing shuffle behavior; one click opens it. The queue shares the
sidebar's artwork tint. A host can create/copy an expiring invite, a second client
joins, follows play/pause/seek/track changes, and loses access when the host ends
the session. Missing apps land on a useful download page. Test expired tokens,
wrong roles, reconnects, queue changes, HTTP ranges, and cold/warm app links.

## Protocol

The gaze service is the authority for session membership and playback snapshots.
Hosts authenticate with their existing Jellyfin account to create a session.
They then use a distinct short-lived host capability; guest credentials can
never call the account/import API. Invitations use a random 12-character URL-safe code (72 bits) in /party/<code>.
Only its hash is retained by the service. Joining exchanges it for an individual
participant token. The landing page sends no referrers, and has no third-party
resources. Codes expire with the session; older fragment invites remain parsable. No Jellyfin token, stream URL, file path, or
Spotify credential is returned to guests. End, expiry, and host disappearance
revoke access. Sessions are memory-only and expire on service restart.

Host playback remains on the normal shared playback controller. One-second
heartbeats publish the track, position, play state, and actual queue order.
Guests estimate the server clock from request round-trip time, apply the same
playback state, and correct significant drift through the shared controller.
This is synchronized listening over the network, not sample-accurate audio.
Guests can search the host’s available music, add songs, remove upcoming songs,
reorder, skip, go back, pause/play, and seek. Each guest retains their own volume.
Shared commands have a monotonic version; stale host heartbeats cannot undo
commands. Queue entries have distinct slot IDs so duplicate songs can be edited
without removing the wrong occurrence. The host applies new server commands
through the shared playback controller and acknowledges their version.

The service validates every new queue item against the host's library and proxies
only session-listed audio/artwork. Streaming supports ranges and propagates
cancellation, without buffering songs in memory. Invite links are bearer access:
share them only with intended listeners. Limit each session to 12 participants,
1,000 queued items, and 12 hours. The host must remain connected; guest edits do not extend its heartbeat. Guests pause
on stale heartbeats. Guest audio requires explicit GAZE_PARTY_GUESTS=true.

## Deployment

Set GAZE_PUBLIC_ORIGIN to your dedicated HTTPS origin. Route a dedicated
Cloudflare Tunnel hostname to gaze-service:8097 (or its host port), with no
caching for API/media endpoints. Do not expose Jellyfin itself or share another
application's tunnel credentials. GAZE_PARTY_GUESTS enables invite-only access.
The root and /party/<id> serve the same static landing page. The page has no
third-party scripts, analytics, fonts, or tracking. Open in gaze uses a gaze://
link; download points to the public GitHub releases page.

Linux protocol registration is performed by the user-level installer. GTK's
single-instance action forwards an invite to the running app, or queues it until
Dart is ready on cold start. The app also accepts pasted HTTPS invite links,
which is the platform-neutral fallback. Native Windows/macOS protocol launch
must be verified on those platforms before advertising it as tested.
