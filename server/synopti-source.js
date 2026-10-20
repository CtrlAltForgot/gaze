import {youtubeUrl} from './store.js';

export const legacyArtistError = 'Synopti could not identify the artist. Confirm the song title and artist before importing.';

export function knownYoutubeSource(value) {
  try { return value ? youtubeUrl(value) : null; } catch { return null; }
}

// Recover only the old metadata gate, never failures, manual choices, saved
// files, ignored videos, another account, or a disabled Synopti connection.
export function recoverSynoptiSources(store) {
  const ownerId = store.data.botOwner;
  const owner = ownerId && store.owner(ownerId);
  if (!owner?.botEnabled) return 0;
  let count = 0;
  for (const job of Object.values(store.data.jobs)) {
    if (job.owner !== ownerId || job.kind !== 'Synopti' ||
        job.status !== 'needsMatch' || !job.unidentified ||
        job.error !== legacyArtistError || job.manualMatch || job.relative) continue;
    const url = knownYoutubeSource(job.youtubeUrl);
    if (!url) continue;
    job.youtubeUrl = url;
    job.status = (owner.ignoredYoutubeUrls || []).includes(url) ? 'ignored' : 'queued';
    job.sourceConfirmed = true;
    job.error = null;
    job.nextAttempt = 0;
    job.updatedAt = Date.now();
    count++;
  }
  if (count) store.save();
  return count;
}

// Metadata improves labels; the already-played recording is the authority for
// the source. An uploader/channel name is not treated as an artist credit.
export function applySynoptiCredits(job, info) {
  if (job.kind !== 'Synopti' || !job.unidentified || job.manualMatch) return;
  const text = value => typeof value === 'string' ? value.trim().slice(0, 250) : '';
  const artists = (Array.isArray(info.artists) ? info.artists : [info.artist])
    .map(text).filter(Boolean).slice(0, 20);
  const original = job.originalTitle || job.title;
  const split = original.match(/^(.+?)\s+(?:-|–|—|\/\/)\s+(.+)$/u);
  const creditedArtists = artists.length ? artists : split ? [text(split[1])] : [];
  if (!creditedArtists.length) {
    job.metadataStatus = 'artistMissing';
    return;
  }
  job.originalTitle ??= original;
  job.artists = creditedArtists;
  job.title = text(info.track) || (split ? text(split[2]) : job.title);
  job.unidentified = false;
  job.metadataStatus = artists.length ? 'sourceCredits' : 'videoTitle';
}
