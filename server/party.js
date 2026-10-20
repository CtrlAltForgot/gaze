import {randomBytes, createHash, timingSafeEqual} from 'node:crypto';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';

const secret = () => randomBytes(32).toString('base64url');
const hash = value => createHash('sha256').update(value).digest();
const matches = (value, digest) => typeof value === 'string' && value.length <= 128 && timingSafeEqual(hash(value), digest);
const fail = (message, status = 400) => { throw Object.assign(Error(message), {status}); };
const idPattern = /^[a-f0-9]{32}$/i;

export class Parties {
  constructor({jellyfin, publicOrigin, guests = false, now = Date.now, fetchImpl = fetch}) {
    this.jellyfin = jellyfin; this.now = now; this.fetch = fetchImpl; this.guests = guests;
    this.sessions = new Map(); this.attempts = new Map(); this.creating = new Set(); this.invites = new Map();
    if (publicOrigin) {
      const u = new URL(publicOrigin);
      if (u.protocol !== 'https:' || u.username || u.password || u.search || u.hash || u.pathname !== '/') throw Error('GAZE_PUBLIC_ORIGIN must be an HTTPS origin.');
      this.origin = u.origin;
    }
  }
  prune() {
    for (const [id, s] of this.sessions) {
      if (s.expiresAt <= this.now() || s.hostSeen < this.now() - 120000) this.end(id);
      else for (const [key, guest] of s.members) if (guest.seen < this.now() - 45000) { this.abortStreams(s, key); s.members.delete(key); }
    }
    for (const [key, value] of this.attempts) if (value.at < this.now() - 60000) this.attempts.delete(key);
  }
  rateLimit(key, limit = 20) {
    this.prune();
    const value = this.attempts.get(key) || {at: this.now(), count: 0};
    if (++value.count > limit) fail('Too many session requests. Try again in a minute.', 429);
    if (this.attempts.size < 10000 || this.attempts.has(key)) this.attempts.set(key, value);
    else fail('The service is busy. Try again shortly.', 429);
  }
  async tracks(owner, ids, old = []) {
    if (!Array.isArray(ids) || !ids.length || ids.length > 1000 || ids.some(id => typeof id !== 'string' || !idPattern.test(id))) fail('Choose a queue of up to 1,000 library songs.');
    const cached = new Map(old.map(t => [t.id, t]));
    const missing = [...new Set(ids.filter(id => !cached.has(id)))];
    const library = missing.length > 8 && (this.jellyfin.partyItems || this.jellyfin.songs) ? new Map((await (this.jellyfin.partyItems ? this.jellyfin.partyItems(owner, missing) : this.jellyfin.songs(owner))).map(item => [item.Id, item])) : null;
    const result = [];
    // Serial bounded lookups; repeated queue slots retain their order.
    for (const id of ids) {
      if (!cached.has(id)) {
        const item = library ? library.get(id) : await this.jellyfin.item(owner, id);
        if (!item || item.Type !== 'Audio' || item.Id !== id) fail('A queued song is unavailable to this account.', 403);
        cached.set(id, {id, title: String(item.Name || 'Untitled').slice(0, 250), artist: (item.Artists || []).join('; ').slice(0, 500), durationMs: Math.round((item.RunTimeTicks || 0) / 10000), artworkId: item.ImageTags?.Primary ? id : (item.AlbumId && item.AlbumPrimaryImageTag ? item.AlbumId : null)});
      }
      result.push(cached.get(id));
    }
    return result;
  }
  async create(owner, data) {
    this.prune();
    if (!this.origin || !this.guests) fail('Party Sessions are not configured on this server.', 503);
    if (this.sessions.size >= 50) fail('This server has reached its Party Session limit.', 429);
    if ([...this.sessions.values()].filter(s => s.owner.id === owner.id).length >= 2) fail('End an existing Party Session before starting another.');
    if (this.creating.has(owner.id)) fail('A session is already being created.', 409);
    this.creating.add(owner.id);
    let queue;
    try { queue = await this.tracks(owner, data.queue); }
    finally { this.creating.delete(owner.id); }
    const id = randomBytes(16).toString('hex'), invite = randomBytes(9).toString('base64url'), host = secret();
    const s = {id, owner, invite: hash(invite), host: hash(host), members: new Map(), streams: new Set(), queue: this.withSlots(queue), revision: 1, commandVersion: 0, hostSeen: this.now(), updatedAt: this.now(), expiresAt: this.now() + 12 * 3600000};
    this.setPlayback(s, data);
    this.sessions.set(id, s); this.invites.set(hash(invite).toString('hex'), id);
    return {id, token: host, inviteUrl: `${this.origin}/party/${invite}`, ...this.snapshot(s)};
  }
  session(id) {
    this.prune();
    const s = this.sessions.get(id);
    if (!s) fail('This Party Session has ended or expired.', 410);
    return s;
  }
  authorize(id, token, hostOnly = false) {
    const s = this.session(id);
    if (matches(token, s.host)) return s;
    if (!hostOnly && typeof token === 'string' && token.length <= 128) {
      const member = s.members.get(hash(token).toString('hex'));
      if (member) { member.seen = this.now(); return s; }
    }
    fail(hostOnly ? 'Only the host can control this session.' : 'This session invitation or membership is invalid.', 403);
  }
  join(id, invite, name) {
    const s = this.session(id);
    if (!matches(invite, s.invite)) fail('This invitation is invalid.', 403);
    if (s.members.size >= 12) fail('This session is full.', 409);
    const token = secret();
    s.members.set(hash(token).toString('hex'), {name: String(name || 'Listener').trim().slice(0, 40) || 'Listener', seen: this.now()});
    return {token, ...this.snapshot(s)};
  }
  setPlayback(s, data) {
    if (!Number.isInteger(data.index) || data.index < 0 || data.index >= s.queue.length || typeof data.playing !== 'boolean' || !Number.isFinite(data.positionMs) || data.positionMs < 0 || data.positionMs > 86400000) fail('Invalid playback state.');
    s.index = data.index; s.playing = data.playing; s.positionMs = Math.round(data.positionMs); s.updatedAt = this.now();
  }
  async update(id, token, data) {
    const s = this.authorize(id, token, true);
    if (s.updating) fail('A session update is already running.', 409);
    s.hostSeen = this.now();
    if ((data.commandVersion ?? 0) !== s.commandVersion) return this.snapshot(s);
    s.updating = true;
    const version = s.commandVersion;
    try {
    if (data.queue) {
      const queue = await this.tracks(s.owner, data.queue, s.queue);
      if (version !== s.commandVersion) return this.snapshot(s);
      // Validate as a unit before replacing the current queue.
      const next = {...s, queue}; this.setPlayback(next, data);
      for (const stream of s.streams) if (!queue.some(t => t.id === stream.itemId)) stream.abort.abort();
      Object.assign(s, {queue: this.withSlots(queue, s.queue), index: next.index, playing: next.playing, positionMs: next.positionMs, updatedAt: next.updatedAt}); s.revision++;
    } else this.setPlayback(s, data);
    return this.snapshot(s, false);
    } finally { s.updating = false; }
  }
  snapshot(s, includeQueue = true) {
    const now = this.now();
    return {id: s.id, hostName: s.owner.name, serverTime: now, expiresAt: s.expiresAt, revision: s.revision, commandVersion: s.commandVersion, connected: now - s.hostSeen < 10000, updatedAt: s.updatedAt, index: s.index, playing: s.playing && now - s.hostSeen < 10000, positionMs: s.positionMs, ...(includeQueue ? {queue: s.queue.map(({artworkId, ...track}) => ({...track, hasArtwork: !!artworkId}))} : {}), listeners: [...s.members.values()].map(m => m.name)};
  }
  withSlots(queue, old = []) {
    const slots = new Map();
    for (const item of old) { if (!slots.has(item.id)) slots.set(item.id, []); slots.get(item.id).push(item.slot); }
    return queue.map(item => ({...item, slot: slots.get(item.id)?.shift() || randomBytes(9).toString('base64url')}));
  }
  joinInvite(code, name) {
    this.prune();
    const id = typeof code === 'string' && /^[\w-]{12}$/.test(code) ? this.invites.get(hash(code).toString('hex')) : null;
    if (!id) fail('This Party Session has ended or the invitation is invalid.', 410);
    return this.join(id, code, name);
  }
  async search(id, token, query) {
    const s = this.authorize(id, token);
    const q = String(query || '').trim().toLowerCase().slice(0, 100);
    if (q.length < 2) return {songs: []};
    const items = await (this.jellyfin.partySearch ? this.jellyfin.partySearch(s.owner, q) : this.jellyfin.songs(s.owner));
    this.authorize(id, token);
    return {songs: items.filter(item => item.Type === 'Audio' && (String(item.Name) + ' ' + (item.Artists || []).join(' ')).toLowerCase().includes(q)).slice(0, 40).map(item => ({id:item.Id, title:item.Name || 'Untitled', artist:(item.Artists || []).join('; '), durationMs:Math.round((item.RunTimeTicks || 0)/10000)}))};
  }
  async command(id, token, data) {
    const live = this.authorize(id, token);
    // Bound all participant actions separately from joining.
    this.rateLimit('command:' + hash(token).toString('hex'), 120);
    let added;
    if (data.action === 'add') added = this.withSlots(await this.tracks(live.owner, [data.itemId]));
    this.authorize(id, token);
    const s = {...live, queue: [...live.queue]};
    const now = this.now();
    if (s.playing) s.positionMs += Math.max(0, now - s.updatedAt);
    const findSlot = () => { const i = s.queue.findIndex(t => t.slot === data.slot); if (i < 0) fail('The queue changed. Try again.', 409); return i; };
    switch (data.action) {
      case 'add':
        if (s.queue.length >= 1000) fail('The shared queue is full.');
        s.queue.push(...added); s.revision++; break;
      case 'remove': {
        const i = findSlot();
        if (i === s.index) fail('Skip the current song before removing it.');
        s.queue.splice(i, 1); if (i < s.index) s.index--; s.revision++; break;
      }
      case 'move': {
        const from = findSlot(), to = s.queue.findIndex(t => t.slot === data.before);
        if (from <= s.index || to <= s.index) fail('Only upcoming songs can be reordered.');
        if (from !== to) { const [item] = s.queue.splice(from,1); s.queue.splice(s.queue.findIndex(t => t.slot === data.before) + (data.after === true ? 1 : 0),0,item); s.revision++; } break;
      }
      case 'clear': s.queue.splice(s.index + 1); s.revision++; break;
      case 'next': if (s.index + 1 < s.queue.length) {s.index++; s.positionMs = 0; s.playing = true;} break;
      case 'previous': s.index = Math.max(0,s.index - 1); s.positionMs = 0; s.playing = true; break;
      case 'playAt': s.index = findSlot(); s.positionMs = 0; s.playing = true; break;
      case 'play': s.playing = true; break;
      case 'pause': s.playing = false; break;
      case 'seek':
        if (!Number.isFinite(data.positionMs) || data.positionMs < 0 || data.positionMs > 86400000) fail('Invalid playback position.');
        s.positionMs = Math.min(data.positionMs, s.queue[s.index].durationMs || 86400000); break;
      default: fail('Unknown session action.');
    }
    s.updatedAt = now; s.commandVersion++;
    Object.assign(live, s);
    for (const stream of s.streams) if (!s.queue.some(t => t.id === stream.itemId)) stream.abort.abort();
    return this.snapshot(s);
  }
  abortStreams(s, memberKey = null) {
    for (const stream of s.streams) if (memberKey === null || stream.memberKey === memberKey) stream.abort.abort();
  }
  end(id) { const s = this.sessions.get(id); if (s) this.abortStreams(s); this.sessions.delete(id); for (const [key, value] of this.invites) if (value === id) this.invites.delete(key); }
  leave(id, token) {
    const s = this.authorize(id, token);
    if (matches(token, s.host)) { this.end(id); return; }
    const key = hash(token).toString('hex'); this.abortStreams(s, key); s.members.delete(key);
  }
  async media(req, res, id, token, itemId, artwork = false) {
    const s = this.authorize(id, token);
    const track = s.queue.find(t => t.id === itemId);
    if (!track) fail('This song is not in the shared queue.', 403);
    if (artwork && !track.artworkId) fail('No artwork is available.', 404);
    const range = req.headers.range;
    if (range && !/^bytes=\d*-\d*$/.test(range)) fail('Invalid audio range.', 416);
    const url = new URL(this.jellyfin.origin);
    url.pathname = url.pathname.replace(/\/$/, '') + (artwork ? `/Items/${track.artworkId}/Images/Primary` : `/Audio/${itemId}/stream`);
    url.search = artwork ? 'maxWidth=600&quality=90' : 'static=true';
    const abort = new AbortController();
    const stream = {abort, itemId, memberKey: hash(token).toString('hex')}; s.streams.add(stream);
    const cancel = () => abort.abort();
    res.on('close', cancel);
    try {
      const upstream = await this.fetch(url, {headers: {'X-Emby-Token': s.owner.token, ...(range && !artwork ? {range} : {})}, redirect: 'error', signal: AbortSignal.any([abort.signal, AbortSignal.timeout(120000)])});
      if (![200, 206].includes(upstream.status)) { await upstream.body?.cancel(); fail('This session song is unavailable.', upstream.status === 416 ? 416 : 502); }
      const headers = {'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff'};
      for (const key of ['content-type', 'content-length', 'content-range', 'accept-ranges']) if (upstream.headers.has(key)) headers[key] = upstream.headers.get(key);
      res.writeHead(upstream.status, headers);
      await pipeline(Readable.fromWeb(upstream.body), res);
    } finally { res.off('close', cancel); s.streams.delete(stream); }
  }

  async lyrics(id, token, itemId) {
    const checkAccess = () => {
      const s = this.authorize(id, token);
      if (!s.queue.some(track => track.id === itemId)) fail('This song is not in the shared queue.', 403);
      return s;
    };
    const s = checkAccess();
    this.rateLimit('lyrics:' + hash(token).toString('hex'), 60);
    const url = new URL(this.jellyfin.origin);
    url.pathname = url.pathname.replace(/\/$/, '') + `/Audio/${itemId}/Lyrics`;
    url.search = '';
    let data;
    try {
      const response = await this.fetch(url, {
        headers: {'X-Emby-Token': s.owner.token}, redirect: 'error',
        signal: AbortSignal.timeout(10000),
      });
      if (response.status === 404) {
        await response.body?.cancel();
        data = null;
      } else {
        if (!response.ok) { await response.body?.cancel(); throw Error('upstream'); }
        const chunks = []; let size = 0;
        for await (const chunk of response.body) {
          size += chunk.length;
          if (size > 512 * 1024) throw Error('size');
          chunks.push(chunk);
        }
        data = JSON.parse(Buffer.concat(chunks).toString());
        if (!Array.isArray(data?.Lyrics) || data.Lyrics.length > 5000) throw Error('lyrics');
      }
    } catch {
      checkAccess();
      fail('Lyrics are temporarily unavailable. Try again.', 502);
    }
    // Membership or the queue may have changed while Jellyfin was responding.
    checkAccess();
    if (data === null) return null;
    return {
      isSynchronized: data.Metadata?.IsSynced === true,
      lines: data.Lyrics.filter(line => typeof line?.Text === 'string').map(line => ({
        text: line.Text,
        ...(Number.isSafeInteger(line.Start) && line.Start >= 0
          ? {startMicroseconds: Math.floor(line.Start / 10)} : {}),
      })),
    };
  }
}
