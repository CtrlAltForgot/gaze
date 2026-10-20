# gaze service

This companion service owns imports, linked Spotify playlists, manual matches,
and background import processing. Jellyfin supplies the current account identity and stores
playable music and private playlist objects. A later gaze mobile client can use
this same account API. The desktop app is not required to stay open while an explicitly requested import finishes.

The Node runtime and matching adapter reuse Synopti's installed Spotify/YouTube
matching tools in a separate container. This does not turn the voice bot into
a download worker. Only a metadata reporting hook is added to the bot.

## Acceptance

- Played-song events are durable, exclude signed stream URLs, and cannot block
  playback. Only the configured Discord guild and gaze account are ingested.
- Title plus normalized artist names identify existing music. Editions such as
  live, clean, remix, and explicit retain their metadata and matching safeguards.
- Every Spotify page and an unchanged snapshot are required before changing a
  mirror. Null/local/unavailable entries remain counted, not silently complete.
- Private mirrored playlists are created by this service. Existing unrelated
  playlists and source music files are never removed by sync.
- The sync queue contains only unresolved imports. Saved and ignored jobs stay
  in durable history for deduplication and playlist mirroring, with a separate saved
  count. Needs attention opens by default; in-progress work remains accessible.
  Exact manual YouTube links are validated per entry.
- Audio-only formats are tried from highest to lowest quality. If none downloads,
  combined video/audio formats are tried and only their original audio is saved.
  Partial downloads are cleared between attempts. Tagging uses stream copy. Codec, sample rate, channels, and
  the SHA-256 of compressed audio packets must remain identical before publish.
- Saves use a staging area and atomic no-overwrite publish. Restarted downloads
  recover; indexed-file waits never download a second copy. Each worker pass checks
  all pending saved files against one complete library snapshot per account before
  starting another queued download, so a backlog cannot hide indexed songs.
- Account tokens and Spotify refresh tokens live in mode-0600 service files;
  API responses and logs exclude them. Authentication is validated by Jellyfin
  on every API request. Spotify credentials are separately scoped by account.

## Configuration

Run one instance with persistent storage. The container inherits a compatible
Synopti image (Node 22, yt-dlp, FFmpeg, ytmusicapi, spotify-url-info). Use the
Dockerfile in this directory with this directory as its build context. Pin the
base image used by your deployed bot; do not rebuild/restart unrelated workers.

Required environment:

- `JELLYFIN_URL`: server origin reachable from the container.
- `SYNOPTI_GUILD_ID`: the allowed music-bot guild.
- `JELLYFIN_MUSIC_PATH`: path Jellyfin sees for the imported subfolder.

Mounts:

- `/gaze-data`: writable, durable private state, credentials, and staging.
- `/music`: writable, a new subfolder inside the existing music library.
- `/synopti-data`: read-only Synopti state, existing OAuth configuration, confirmed
  recording matches, and the `gaze-events` metadata outbox.

Optional environment: `GAZE_PORT` (8097), `GAZE_BIND` (0.0.0.0), `GAZE_DATA`,
`GAZE_MUSIC`, `SYNOPTI_FEED`, `SYNOPTI_SETTINGS`, `SYNOPTI_SPOTIFY_FILE`, and
`SYNOPTI_MODULE_ROOT`. Configure a trusted HTTPS proxy for remote access; local
LAN access follows the existing Jellyfin deployment. No public endpoint is
created by the source code.

Configure the bot's `GAZE_EVENTS_DIR=/data/gaze-events`, then restart only the bot
at an authorized time. Events represent the audio player starting, including
its resolved YouTube video; recoveries of the same queue entry are idempotent.
The service does not read queued songs as if they had played. User-excluded video links are retained in account state and cannot be imported by later bot events.

## Spotify and playlist behavior

The user can explicitly reuse Synopti's current Spotify account (Jellyfin admin
only), or sign in through PKCE. A desktop sign-in uses a temporary loopback
listener; register `http://127.0.0.1/spotify/callback` in the Spotify app. The
client ID can come from existing Synopti configuration. Spotify development-mode
account/allowlist and API access restrictions still apply.

Select only the playlists wanted. The service syncs linked playlists only when the user selects Sync now. Spotify controls membership,
name, and order of the linked copy. Newly resolved songs join that copy in
source order. Playlist duplicates follow Jellyfin's unique-song behavior.
Removing a song from Spotify removes it from the linked playlist, while retaining
the imported music file. Pausing/unlinking does not delete a playlist or music.
Disconnecting Spotify pauses its linked sources. Changes made directly to an
active mirror in another Jellyfin client will be overwritten by the next sync.

The same title and artist can reuse an existing library recording; imports do
not replace or re-encode the user's existing music. YouTube can supply only the
formats accessible for that video. A lossy source stays lossy, and FLAC conversion
cannot restore missing information. No premium-quality entitlement, DRM bypass,
or audio enhancement is implied. Download failures remain visible, with retry
and a manual source choice.

`npm test` exercises real stream-copy preservation as well as account isolation,
deduplication, interrupted downloads, source snapshot guards, and review states.
Back up `/gaze-data` together with the imported media. State is a single-writer,
versioned, fsync-and-rename JSON snapshot, not a distributed database. External
OAuth and Jellyfin failures retain existing mirrors. If an account's Jellyfin
token is revoked, sign in through gaze again to refresh background access.

Spotify updates are manual only. The service never polls Spotify on a timer;
import and Sync now are the only playlist refresh triggers. Synopti played-song
reporting and completion of already requested downloads remain active.

Matching starts with Synopti's resolver and its availability checks. If flat
YouTube search omits artist attribution, gaze inspects full video metadata for
up to five candidates of the correct duration before applying the same title,
artist, version, and explicitness checks. An extended first result never
automatically stands in for the original recording.

Indexing reports the new import root and file to Jellyfin, and requests a
bounded refresh of only the containing music library when the nested root is
not yet registered. Imported files are marked saved only after an independent
Jellyfin library lookup sees them and the linked playlist save is verified.

For soundtrack reuploads with no structured artist field, a description link
to the matching artist's Bandcamp album can supply the missing artist credit.
The artist subdomain and album name must both match, and existing structured
artist data is never replaced. Title, duration, explicitness, and version guards
still apply. The chosen attribution is recorded in the match receipt.

## Missing album artwork

Artwork is repaired separately from audio imports and playlist synchronization.
After a song is indexed, gaze preserves any existing song/album cover. For a
missing album cover it first tries the artwork URL saved with identified Spotify
metadata (including Spotify songs reported by Synopti), then searches MusicBrainz
and the Cover Art Archive, followed by Apple Music and YouTube Music catalog fallbacks. Album title and credited artists must match; YouTube
video thumbnails are not used as album covers. An album is searched once and its
cover is shared by its songs. Generic folders such as “Singles” remain unresolved
rather than receiving one unrelated cover for every song.

The Connect screen's **Find missing artwork** starts a manual library scan and
retries unresolved searches. It does not refresh Spotify playlists. New gaze
imports get an automatic attempt, including imports completed before this feature
was installed. No recurring whole-library or Spotify refresh is scheduled.
Jellyfin requires an administrator for saving library images. Save rechecks the
album for an existing Primary image immediately before upload, verifies the saved
image tag, and invalidates metadata cache. Images are separate from audio files:
no audio retagging, remuxing, re-encoding, or song-file overwrite occurs.

Searches have a persistent album queue, bounded response sizes and dimensions,
validated provider redirects, serial requests spaced by at least 1.1 seconds,
provider cooldown on rate limits, and at most three attempts for temporary provider
failure. Negative results wait for another manual search. Set
`GAZE_ARTWORK_USER_AGENT` to `gaze/0.1 (your public contact URL or email)` for
MusicBrainz requests. Stored artwork URLs are reused without a Spotify API call.
Failures remain visible and never change a song's ready status or playlist.

Artwork acceptance: preserve existing covers, reject wrong artists/editions and
video thumbnails, share one album lookup, survive restart/offline/rate limits,
keep original song hashes unchanged, and verify actual Jellyfin image availability.

### Resilient catalog artwork — October 2026

The artwork search can continue to another provider when one is unavailable.
Rate-limit cooldowns do not consume a queued album's network-attempt budget.
Spotify source URLs remain first choice. Apple Music search is limited to fewer
than 20 starts per minute. Public YouTube Music song search uses the already
installed ytmusicapi 1.12.3 client; no sign-in, cookies, or audio download is used.
Both catalogs receive only the album/song title and primary artist search text.

Catalog images require exact release and credited-artist matching. A one-song
folder named after its song may instead use that exact song's actual release
cover, with artist and duration corroboration. Remix/live edition text is retained;
wrong artists, mixed-song folders, and mismatched versions are rejected. Featured
credits and single/EP suffixes are understood. The server requests 600 px images,
validates the returned bytes/dimensions, and saves them through the existing
missing-cover-only Jellyfin path. Raw video thumbnails are not searched.

Artist artwork recovery uses YouTube Music artist results corroborated by an exact song title and the same catalog artist ID. Existing artist images are preserved. Combined credits and artists without a verified portrait can use a cover from their own Jellyfin music; unrelated portraits are never substituted. The background worker discovers newly added artists hourly and retries unmatched identities daily, with provider cooldowns. Artist names and song titles may be sent to the public catalog; audio and credentials remain local.


## Party Sessions

Set `GAZE_PUBLIC_ORIGIN` to the dedicated public HTTPS origin and
`GAZE_PARTY_GUESTS=true` to enable invite-only guests. The existing service then
serves the landing page, session state, and scoped audio streams on port 8097.
A standalone deployment without Synopti uses `Dockerfile.party` and
`node party-server.js`. See [Party Sessions](../docs/PARTY_SESSIONS.md) for
limits, authentication, and deployment details.
