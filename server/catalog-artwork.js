import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {normalized} from './store.js';

const execute = promisify(execFile);
const helper = fileURLToPath(new URL('./youtube-music-artwork.py', import.meta.url));
const feature = /\s*[([](?:feat\.?|ft\.?|featuring|with)\s+([^\])]+)[\])]/gi;
const key = value => normalized(String(value || '').replace(/[’']/g, ''));
const title = value => key(String(value || '').replace(feature, ''));
const albumTitle = value => title(String(value || '').replace(/\s+-\s+(Single|EP)$/i, ''));
const names = values => values.flatMap(value => String(value || '').split(/\s*[,;]\s*|\s+&\s+/)).map(key).filter(Boolean);

function credits(candidate) {
  const featured = [...String(candidate.title || '').matchAll(feature)].map(match => match[1]);
  return names([...(candidate.artists || []), ...featured]);
}

// A single imported song can be stored in a folder named after the song. Only
// that specific case permits a song match to supply its actual release cover.
export function coverMatchScore(candidate, identity) {
  if (!candidate.album || !candidate.image || !candidate.artists?.length) return 0;
  const expected = names(identity.artists || []);
  const actual = credits(candidate);
  const fullCredits = expected.length > 0 && expected.every(name => actual.includes(name));
  const songs = identity.songs || [];
  const single = songs.length === 1 && title(identity.album) === title(songs[0].title);
  const sameRelease = albumTitle(candidate.album) === albumTitle(identity.album) && fullCredits;
  if (!single) return sameRelease ? 100 : 0;
  const song = songs[0];
  if (!title(song.title) || title(candidate.title) !== title(song.title)) return 0;
  const expectedSong = names(song.artists?.length ? song.artists : identity.artists);
  const durationDifference = Math.abs((candidate.duration || 0) - (song.duration || 0));
  const durationMatches = candidate.duration > 0 && song.duration > 0 && durationDifference <= 4;
  const allSongCredits = expectedSong.length > 0 && expectedSong.every(name => actual.includes(name));
  // Some imported credits contain both an artist's stage and legal name. An
  // exact title, primary artist, and duration can corroborate that case.
  const primaryAndDuration = expectedSong[0] === actual[0] && durationMatches;
  if (!allSongCredits && !primaryAndDuration) return 0;
  if (candidate.duration > 0 && song.duration > 0 && durationDifference > 12) return 0;
  return (sameRelease ? 100 : 70) + (allSongCredits ? 10 : 0) + (durationMatches ? 5 : 0);
}

export async function youtubeMusicCandidates(query) {
  const {stdout} = await execute('python3', [helper, query], {
    timeout: 45000, maxBuffer: 512 * 1024,
  });
  const result = JSON.parse(stdout);
  if (!Array.isArray(result)) throw new Error('The music catalog returned invalid results.');
  return result.slice(0, 20);
}

export class CatalogArtwork {
  constructor({search, youtube = youtubeMusicCandidates}) {
    this.search = search;
    this.youtube = youtube;
    this.youtubeRetryAt = 0;
    this.youtubeRequests = 0;
    this.appleNextAt = 0;
  }

  async find(identity) {
    const artist = (identity.artists?.[0] || '').split(/[,;]/)[0];
    if (!artist || !identity.album) return null;
    const query = `${artist} ${identity.album}`;
    let unavailable;
    let cleanEditions = [];
    // Keep Apple requests below its documented approximate 20/minute limit.
    try {
      const delay = this.appleNextAt - this.search.now();
      if (delay > 0) await this.search.wait(delay);
      this.appleNextAt = this.search.now() + 3100;
      const url = new URL('https://itunes.apple.com/search');
      url.search = new URLSearchParams({term: query, entity: 'song', media: 'music', country: 'US', limit: '25'});
      const data = await this.search.json(url);
      const candidates = (data?.results || []).filter(item => item.kind === 'song').map(item => ({
        title: item.trackName,
        artists: [item.artistName],
        album: item.collectionName,
        duration: Number(item.trackTimeMillis) / 1000,
        image: item.artworkUrl100?.replace(/\/100x100bb\.(jpg|png)$/, '/600x600bb.$1'),
        source: 'Apple Music',
        sourceUrl: item.trackViewUrl,
        cleanEdition: item.trackExplicitness === 'cleaned',
      }));
      // Prefer the standard release when the catalog offers only a censored
      // edition first. Retain that edition as a last resort if nothing else fits.
      cleanEditions = candidates.filter(candidate => candidate.cleanEdition);
      const image = await this.select(candidates.filter(candidate => !candidate.cleanEdition), identity);
      if (image) return image;
    } catch (error) { unavailable = error; }
    if (this.search.now() < this.youtubeRetryAt) {
      unavailable ||= Object.assign(new Error('YouTube Music is cooling down.'), {
        attempted: false, retryAfter: this.youtubeRetryAt - this.search.now(),
      });
    } else {
      let candidates;
      try {
        this.youtubeRequests++;
        candidates = await this.youtube(query);
      } catch (error) {
        this.youtubeRetryAt = this.search.now() + 60000;
        unavailable = error;
      }
      if (candidates) {
        try {
          const image = await this.select(candidates, identity);
          if (image) return image;
        } catch (error) { unavailable = error; }
      }
    }
    if (cleanEditions.length) {
      try {
        const image = await this.select(cleanEditions, identity);
        if (image) return image;
      } catch (error) { unavailable = error; }
    }
    if (unavailable) throw unavailable;
    return null;
  }

  async select(candidates, identity) {
    const matches = candidates.map(candidate => ({candidate, score: coverMatchScore(candidate, identity)}))
      .filter(match => match.score > 0).sort((a, b) => b.score - a.score);
    let unavailable;
    for (const {candidate} of matches.slice(0, 3)) {
      try {
        const image = await this.search.image(candidate.image, candidate.source);
        if (image) return {...image, matchedAlbum: candidate.album, sourceUrl: candidate.sourceUrl};
      } catch (error) { unavailable = error; }
    }
    if (unavailable) throw unavailable;
    return null;
  }
}
