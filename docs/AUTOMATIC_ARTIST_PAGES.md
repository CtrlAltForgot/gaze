# Automatic artist pages

Artist pages are generated from library metadata through a single reusable template. Semicolons and explicit feat./ft./featuring credits become individual artists. Commas, ampersands, slashes, and plus signs are preserved because they occur in real band names. The transport uses semicolons between separate Jellyfin artist entries, preserving their boundaries. No existing tags or server artist records are rewritten.

The client builds a complete canonical artist catalogue across source pages and includes credits from its saved song library. It refreshes when library refresh completes, when reconnecting, or through Refresh artists. New artists need no custom page code. Canonical identities use normalized names; two genuinely different people with exactly the same library name cannot be distinguished until the library supplies separate identities. Public enrichment declines ambiguous identities.

An artist's playable catalogue matches individual track credits exactly, including features. Cached songs appear immediately while the complete library refreshes; concurrent artist navigations share that refresh. Album appearances are derived from those playable songs, instead of relying on Jellyfin's album-artist-only filter. Account and request guards prevent stale navigation results from appearing on another artist's page.

Public profiles use MusicBrainz identities corroborated by available recording titles where possible, then linked Wikidata/Wikipedia identities for biography and a Commons portrait with attribution. Age requires a complete birthday for a living person. Groups show their formation year instead. Public lookups send only the artist name and up to two recording titles to MusicBrainz; subsequent requests use public identifiers. They never send credentials, server addresses or audio. The configured provider is injected, so tests and library-only deployments can disable it. Artist profile lookups require the user's approval before this deployment is enabled. The default build keeps them off; an approved build uses `--dart-define=GAZE_ARTIST_PROFILES=true`.

MusicBrainz calls are paced at least 1.1 seconds apart; successful profiles are cached for seven days. Metadata is fetched only when a profile is opened. Public provider failures leave the music page usable. A missing or ambiguous identity never creates a guessed biography. Photos remain optional and are limited to Wikimedia Commons images with an author and license supplied by Commons. Source links allow reading the full biography and checking the photo license.

“Popular in your library” intersects ListenBrainz's ranked recordings with the selected artist's locally available songs. Matching is conservative: live/remix editions are not collapsed into an unrelated studio recording. If no popularity matches are available, the page says “Songs in your library” rather than presenting an invented ranking.

Artist names in music lists, album cards/details, queue, bottom player and Media Mode are individually clickable and keyboard-accessible. Overflow rests for five seconds, scrolls, then returns smoothly; keyboard focus pauses it and reveals the focused credit. Artist links never trigger row playback. Existing page transitions and reduced-motion behavior remain in effect.

The playlist's main play action uses `playCollection`, which randomly chooses the first queue slot when shuffle is enabled. Explicit track selection continues to use the selected index. Duplicates are preserved as separate queue entries. Random selection can legitimately choose the first original song by chance; it is no longer forced to do so.

## Missing cover verification

No server change is needed. `ArtworkWorker.discover` reads library metadata but enqueues only tracks missing both their own and their album's artwork. The worker checks album artwork before external search; the upload path checks again before writing. Existing artwork is not externally searched or overwritten. The deployed `artwork.js` and `jellyfin.js` hashes matched the checked source on 2026-10-20, and all 68 service regression tests passed.

## Provider references

- https://musicbrainz.org/doc/MusicBrainz_API
- https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
- https://listenbrainz.readthedocs.io/en/latest/users/api/popularity.html
- https://www.mediawiki.org/wiki/Page_Content_Service
- https://www.wikidata.org/wiki/Help:Data_access

Validation and user visual acceptance are recorded separately in the delivery receipt. No meaningful visible changes are committed before user approval.
