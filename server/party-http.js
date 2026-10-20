import fs from 'node:fs';
const landing = fs.readFileSync(new URL('./public/index.html', import.meta.url));
const assets = new Map(['style.css', 'invite.js', 'gaze.png'].map(name => [name, fs.readFileSync(new URL(`./public/${name}`, import.meta.url))]));
const headers = {
  'cache-control': 'no-store', 'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY',
  'content-security-policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};
export async function partyRoute(req, res, url, {parties, jellyfin, readBody, send}) {
  if (req.method === 'GET' && (url.pathname === '/' || /^\/party\/(?:[a-f0-9]{32}|[\w-]{12})$/.test(url.pathname))) {
    res.writeHead(200, {...headers, 'content-type': 'text/html; charset=utf-8'}); res.end(landing); return true;
  }
  const asset = url.pathname.slice(1);
  if (req.method === 'GET' && assets.has(asset)) {
    res.writeHead(200, {...headers, 'content-type': asset.endsWith('.png') ? 'image/png' : asset.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/javascript; charset=utf-8'}); res.end(assets.get(asset)); return true;
  }
  if (!url.pathname.startsWith('/v1/parties') && !url.pathname.startsWith('/v1/party-invites/')) return false;
  if (!parties) { send(res, 503, {error: 'Party Sessions are unavailable.'}); return true; }
  if (req.headers.origin) { send(res, 403, {error: 'Open this invitation in gaze.'}); return true; }
  const shortInvite = url.pathname.match(/^\/v1\/party-invites\/([\w-]{12})$/);
  if (req.method === 'POST' && shortInvite) {
    parties.rateLimit(String(req.headers['cf-connecting-ip'] || req.socket.remoteAddress).slice(0,80));
    const data = await readBody(req); send(res,200,parties.joinInvite(shortInvite[1],data.name)); return true;
  }
  const token = req.headers.authorization?.match(/^Bearer ([\w-]+)$/)?.[1];
  if (!token) { send(res, 401, {error: 'A session credential is required.'}); return true; }
  if (req.method === 'POST' && url.pathname === '/v1/parties') {
    const owner = await jellyfin.authenticate(token);
    send(res, 201, await parties.create(owner, await readBody(req))); return true;
  }
  const route = url.pathname.match(/^\/v1\/parties\/([a-f0-9]{32})(?:\/(join|state|leave|audio|artwork|lyrics|command|search)(?:\/([a-f0-9]{32}))?)?$/);
  if (!route) { send(res, 404, {error: 'Session action not found.'}); return true; }
  const [, id, action, item] = route;
  if (req.method === 'POST' && action === 'join' && !item) {
    // Cloudflare overwrites this header at the edge; the local socket is the
    // fallback. Per-session caps also apply independently of the caller's IP.
    parties.rateLimit(String(req.headers['cf-connecting-ip'] || req.socket.remoteAddress).slice(0, 80));
    const data = await readBody(req); send(res, 200, parties.join(id, token, data.name)); return true;
  }
  if (req.method === 'POST' && action === 'command' && !item) { send(res,200,await parties.command(id,token,await readBody(req))); return true; }
  if (req.method === 'GET' && action === 'search' && !item) { send(res,200,await parties.search(id,token,url.searchParams.get('q'))); return true; }
  if (req.method === 'GET' && action === 'state' && !item) {
    const session = parties.authorize(id, token);
    send(res, 200, parties.snapshot(session, url.searchParams.get('revision') !== String(session.revision))); return true;
  }
  if (req.method === 'POST' && action === 'state' && !item) {
    send(res, 200, await parties.update(id, token, await readBody(req))); return true;
  }
  if (req.method === 'POST' && action === 'leave' && !item) {
    parties.leave(id, token); send(res, 200, {ok: true}); return true;
  }
  if (req.method === 'GET' && ['audio', 'artwork'].includes(action) && item) {
    await parties.media(req, res, id, token, item, action === 'artwork'); return true;
  }
  if (req.method === 'GET' && action === 'lyrics' && item) {
    send(res, 200, {lyrics: await parties.lyrics(id, token, item)}); return true;
  }
  send(res, 404, {error: 'Session action not found.'}); return true;
}
