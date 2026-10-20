import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {Store} from '../store.js';
import {Worker} from '../worker.js';
import {applySynoptiCredits, knownYoutubeSource, legacyArtistError, recoverSynoptiSources} from '../synopti-source.js';

const url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gaze-synopti-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const store = new Store(dir);
  store.data.botOwner = 'owner';
  store.data.owners.owner = {botEnabled: true};
  return {dir, store};
}
const legacy = {kind: 'Synopti', title: 'Artist - Song (Live)', artists: ['Unknown artist'], unidentified: true, youtubeUrl: url, status: 'needsMatch', error: legacyArtistError};

test('recovery releases only the exact legacy artist gate and is durable and idempotent', t => {
  const {dir, store} = fixture(t);
  const job = store.add('owner', legacy);
  Object.assign(job, legacy);
  const protectedCases = [
    {status: 'failed'}, {status: 'ignored'}, {status: 'ready'},
    {manualMatch: true}, {relative: 'saved.opus'}, {kind: 'Spotify'},
    {unidentified: false}, {error: 'A different match needs review'},
    {youtubeUrl: 'https://invalid.example/video'}, {owner: 'other'},
  ];
  for (const [i, change] of protectedCases.entries()) {
    store.data.jobs['protected' + i] = {...legacy, owner: 'owner', ...change};
  }
  const before = structuredClone(protectedCases.map((_, i) => store.data.jobs['protected' + i]));
  assert.equal(recoverSynoptiSources(store), 1);
  assert.equal(job.status, 'queued');
  assert.equal(job.youtubeUrl, url);
  assert.equal(job.error, null);
  assert.equal(job.sourceConfirmed, true);
  assert.equal(recoverSynoptiSources(store), 0);
  assert.deepEqual(protectedCases.map((_, i) => store.data.jobs['protected' + i]), before);
  assert.equal(new Store(dir).data.jobs[job.id].status, 'queued');
});

test('recovery respects a disabled connection and excluded videos', t => {
  const {store} = fixture(t);
  const job = store.add('owner', legacy);
  Object.assign(job, legacy);
  store.owner('owner').botEnabled = false;
  assert.equal(recoverSynoptiSources(store), 0);
  store.owner('owner').botEnabled = true;
  store.owner('owner').ignoredYoutubeUrls = [url];
  assert.equal(recoverSynoptiSources(store), 1);
  assert.equal(job.status, 'ignored');
});

test('a known played recording bypasses search and reaches download even without artist credits', async t => {
  const {store} = fixture(t);
  const job = store.add('owner', legacy);
  let scans = 0, downloads = 0;
  const worker = new Worker({store, jellyfin: {find: async () => null, scan: async () => scans++},
    resolve: () => assert.fail('A played source must never be searched again'),
    download: async received => {
      downloads++;
      assert.equal(received.youtubeUrl, url);
      return {relative: 'saved.opus'};
    }});
  await worker.process(job);
  assert.equal(downloads, 1);
  assert.equal(scans, 1);
  assert.equal(job.status, 'scanning');
});

test('a malformed feed URL stays actionable without preventing the next valid event', t => {
  const {dir, store} = fixture(t);
  const feed = path.join(dir, 'feed'); fs.mkdirSync(feed);
  for (const [file, title, youtubeUrl] of [['aaa', 'Bad source', 'https://other.example/watch'], ['bbb', 'Good source', url]]) {
    fs.writeFileSync(path.join(feed, file + '.json'), JSON.stringify({guildId: 'guild', track: {title, artists: [], youtubeUrl}}));
  }
  new Worker({store, feedDirectory: feed, guildId: 'guild'}).ingest();
  const jobs = Object.values(store.data.jobs);
  assert.equal(jobs.find(j => j.title === 'Bad source').status, 'needsMatch');
  assert.equal(jobs.find(j => j.title === 'Good source').status, 'queued');
  assert.equal(knownYoutubeSource('https://youtube.com.evil/watch?v=dQw4w9WgXcQ'), null);
});

test('structured source credits improve labels without changing recording or stable job ID', () => {
  const job = {...legacy, id: 'stable'};
  applySynoptiCredits(job, {artist: 'Credited Artist', track: 'Song (Live)', uploader: 'Unrelated Channel'});
  assert.deepEqual(job.artists, ['Credited Artist']);
  assert.equal(job.title, 'Song (Live)');
  assert.equal(job.originalTitle, legacy.title);
  assert.equal(job.youtubeUrl, url);
  assert.equal(job.id, 'stable');
  assert.equal(job.metadataStatus, 'sourceCredits');
});

test('video title credits preserve version text; uploader names never become artist credits', () => {
  const job = {...legacy, title: 'Mac DeMarco // On The Level (Official Audio)'};
  applySynoptiCredits(job, {uploader: 'Music Channel'});
  assert.deepEqual(job.artists, ['Mac DeMarco']);
  assert.equal(job.title, 'On The Level (Official Audio)');
  const unknown = {...legacy, title: 'Untitled recording'};
  applySynoptiCredits(unknown, {uploader: 'Music Channel', channel: 'Music Channel'});
  assert.equal(unknown.unidentified, true);
  assert.equal(unknown.metadataStatus, 'artistMissing');
  assert.equal(unknown.youtubeUrl, url);
  const manual = {...legacy, manualMatch: true};
  applySynoptiCredits(manual, {artist: 'Different Artist', track: 'Different Song'});
  assert.equal(manual.title, legacy.title);
});
