import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {Parties} from '../party.js';
import {createServer} from '../http.js';
const a = 'a'.repeat(32), b = 'b'.repeat(32), owner = {id:'owner', name:'Host', token:'private-jellyfin-token'};
const input = {queue:[a,b,a], index:0, playing:true, positionMs:1000};
function setup(extra = {}) {
  let now = 100000;
  const requested=[];
  const jellyfin = {origin:new URL('https://library.invalid'), authenticate:async token => { assert.equal(token, owner.token); return owner; }, item:async (_,id) => { requested.push(id); return {Id:id,Type:id === 'c'.repeat(32)?'Movie':'Audio',Name:`Song ${id[0]}`,Artists:['Artist'],RunTimeTicks:1800000000,ImageTags:{Primary:'cover'}}; }};
  const parties = new Parties({jellyfin, publicOrigin:'https://music.example', guests:true, now:()=>now, ...extra});
  return {parties,jellyfin,requested,advance:ms=>now+=ms};
}

test('invitations exchange for separate scoped credentials; private metadata is absent',async()=>{
  const {parties,requested}=setup(); const host=await parties.create(owner,input);
  const invite=new URL(host.inviteUrl).hash.slice(1), guest=parties.join(host.id,invite,'Friend');
  assert.notEqual(host.token,guest.token);assert.deepEqual(requested,[a,b]);
  assert.equal(guest.queue.length,3);assert.equal(guest.queue[0].id,guest.queue[2].id);
  assert(!JSON.stringify(guest).includes(owner.token));assert(!JSON.stringify(guest).includes('library.invalid'));assert(!JSON.stringify(guest).includes('artworkId'));
  assert.throws(()=>parties.authorize(host.id,invite),/invalid/);
  await assert.rejects(parties.update(host.id,guest.token,{index:1,playing:false,positionMs:2000}),/Only the host/);
  const state=await parties.update(host.id,host.token,{index:1,playing:false,positionMs:2000});
  assert.equal(state.index,1);assert.equal(state.playing,false);assert.equal(state.positionMs,2000);
});

test('expiry, stale hosts, capacity, leave and host end revoke access',async()=>{
  const {parties,advance}=setup();const host=await parties.create(owner,input), invite=new URL(host.inviteUrl).hash.slice(1);
  const guest=parties.join(host.id,invite,'Friend');
  for(let i=0;i<11;i++)parties.join(host.id,invite,`Friend ${i}`);
  assert.throws(()=>parties.join(host.id,invite,'Overflow'),/full/);
  parties.leave(host.id,guest.token);assert.throws(()=>parties.authorize(host.id,guest.token),/invalid/);
  advance(11000);assert.equal(parties.snapshot(parties.session(host.id)).playing,false);
  await parties.update(host.id,host.token,{index:0,positionMs:12000,playing:true});
  assert.equal(parties.snapshot(parties.session(host.id)).playing,true);
  advance(121000);assert.throws(()=>parties.authorize(host.id,host.token),/expired/);
  const next=await parties.create(owner,input);parties.leave(next.id,next.token);assert.throws(()=>parties.session(next.id),/expired/);
});

test('validates library audio and atomic state updates',async()=>{
  const {parties}=setup();const host=await parties.create(owner,input);
  await assert.rejects(parties.update(host.id,host.token,{...input,queue:[b],index:4}),/Invalid playback/);
  assert.equal(parties.session(host.id).queue.length,3);
  await assert.rejects(parties.create(owner,{...input,queue:['c'.repeat(32)]}),/unavailable/);
  await assert.rejects(parties.create(owner,{...input,queue:['https://attacker.invalid']}),/library songs/);
  await assert.rejects(parties.create(owner,{...input,queue:Array(1001).fill(a)}),/1,000/);
  const disabled=setup({guests:false}).parties;await assert.rejects(disabled.create(owner,input),/not configured/);
});

test('HTTP landing, participant access, proxy ranges and host-only control',async t=>{
  const upstream=[];
  const {parties,jellyfin}=setup({fetchImpl:async(url,options)=>{upstream.push({url,options});return new Response('abc',{status:206,headers:{'Content-Type':'audio/flac','Content-Range':'bytes 10-12/100','Content-Length':'3'}});}});
  const server=createServer({parties,jellyfin});server.listen(0,'127.0.0.1');await once(server,'listening');t.after(()=>{server.closeAllConnections();server.close();});
  const origin=`http://127.0.0.1:${server.address().port}`;
  const request=(path,token,body,headers={})=>fetch(origin+path,{method:body?'POST':'GET',headers:{...(token?{Authorization:`Bearer ${token}`} : {}),...headers},...(body?{body:JSON.stringify(body)}:{})});
  const landing=await request('/');assert.equal(landing.status,200);assert.match(await landing.text(),/Open|Get gaze/);assert.match(landing.headers.get('content-security-policy'),/frame-ancestors 'none'/);
  const created=await request('/v1/parties',owner.token,input);assert.equal(created.status,201);const host=await created.json();
  const base=`/v1/parties/${host.id}`, invite=new URL(host.inviteUrl).hash.slice(1);
  const guest=await (await request(base+'/join',invite,{name:'Listener'})).json();
  assert.equal((await request(base+'/state',guest.token,{index:0,playing:false,positionMs:0})).status,403);
  const audio=await request(base+'/audio/'+a,guest.token,null,{Range:'bytes=10-12'});assert.equal(audio.status,206);assert.equal(await audio.text(),'abc');
  assert.equal(upstream[0].options.headers['X-Emby-Token'],owner.token);assert.equal(upstream[0].options.headers.range,'bytes=10-12');
  assert.equal(audio.headers.get('cache-control'),'private, no-store');
  assert.equal((await request(base+'/audio/'+'c'.repeat(32),guest.token)).status,403);
  assert.equal((await request(base+'/audio/'+a,guest.token,null,{Range:'bytes=0-2,5-8'})).status,416);
  assert.equal((await request(base+'/state',guest.token,null,{Origin:'https://bad.example'})).status,403);
  await request(base+'/leave',host.token,{});
  assert.equal((await request(base+'/state',guest.token)).status,410);
});

test('host end aborts active audio transfers and join attempts are bounded',async()=>{
  const {parties}=setup();const host=await parties.create(owner,input), s=parties.session(host.id), abort=new AbortController();
  s.streams.add({abort,memberKey:'fake'});parties.leave(host.id,host.token);assert.equal(abort.signal.aborted,true);
  for(let i=0;i<20;i++)parties.rateLimit('test');assert.throws(()=>parties.rateLimit('test'),/Too many/);
});
