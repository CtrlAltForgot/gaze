import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {normalized,trackKey} from './store.js';
import {CatalogArtwork,youtubeMusicCandidates} from './catalog-artwork.js';
const run=promisify(execFile);
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const MAX_IMAGE=12*1024*1024;
const GENERIC=new Set(['singles','unknown album','unknown','various','music']);
function allowed(url){const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password||u.port)throw Error('Unsupported artwork address.');const h=u.hostname;if(!['i.scdn.co','musicbrainz.org','coverartarchive.org','archive.org','itunes.apple.com','yt3.googleusercontent.com','lh3.googleusercontent.com'].includes(h)&&!/^is[0-9]+-ssl\.mzstatic\.com$/.test(h)&&!/^(ia|dn)[0-9]+\.us\.archive\.org$/.test(h)&&!/^(ia|dn)[0-9]+\.[a-z0-9-]+\.archive\.org$/.test(h))throw Error('Unsupported artwork provider.');return u;}
export class ArtworkUnavailable extends Error{constructor(delay=60000,{attempted=true}={}){super('The artwork provider is unavailable. Try the search again later.');this.retryAfter=delay;this.attempted=attempted;}}
export function albumIdentity(album,songs=[]){
 const names=x=>(x||[]).map(a=>typeof a==='string'?a:a?.Name).filter(Boolean);
 const artists=names(album.AlbumArtists).length?names(album.AlbumArtists):album.AlbumArtist?[album.AlbumArtist]:names(album.Artists).length?names(album.Artists):[...new Set(songs.flatMap(s=>s.Artists||[]))];
 // Older untagged music already lives in artist/album folders. Use only that
 // immediate artist folder as a search hint; never rewrite the audio's tags.
 if(!artists.length&&album.Path)artists.push(path.posix.basename(path.posix.dirname(album.Path)));
 return {album:album.Name,artists,providerIds:album.ProviderIds||{},songs:songs.map(song=>({title:song.Name,artists:song.Artists||[],duration:Number(song.RunTimeTicks||0)/10000000}))};
}
export function sameAlbum(candidate,identity){const credits=candidate['artist-credit']||[];return normalized(candidate.title)===normalized(identity.album)&&identity.artists.length>0&&identity.artists.every(a=>credits.some(c=>[c.name,c.artist?.name].some(n=>normalized(n)===normalized(a))));}
export async function imageDetails(bytes,{directory='/tmp',execute=run}={}){
 let type;if(bytes.length>=3&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255)type='image/jpeg';else if(bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))type='image/png';else throw Error('The artwork provider returned an unsupported image.');
 if(bytes.length>MAX_IMAGE)throw Error('The cover image is too large.');fs.mkdirSync(directory,{recursive:true});const file=path.join(directory,'gaze-cover-'+randomUUID());
 try{fs.writeFileSync(file,bytes,{mode:0o600});const {stdout}=await execute('ffprobe',['-v','error','-select_streams','v:0','-show_entries','stream=width,height','-of','json',file],{timeout:15000,maxBuffer:65536});const s=JSON.parse(stdout).streams?.[0];if(!s||s.width<200||s.height<200||s.width>12000||s.height>12000||s.width*s.height>40000000||s.width/s.height<0.7||s.width/s.height>1.4)throw Error('No suitable album cover was found.');return {type,width:s.width,height:s.height};}finally{fs.rmSync(file,{force:true});}
}
export class ArtworkSearch{
 constructor({fetchImpl=fetch,directory='/tmp',inspect=imageDetails,now=Date.now,wait=ms=>new Promise(r=>setTimeout(r,ms)),userAgent='gaze/0.1 (self-hosted Jellyfin music library)',youtube=youtubeMusicCandidates}={}){Object.assign(this,{fetch:fetchImpl,directory,inspect,now,wait,userAgent});this.requests=0;this.lastRequest=0;this.cooldowns=new Map();this.catalog=new CatalogArtwork({search:this,youtube});}
 async response(value,max=1024*1024){
  let u=allowed(value);
  for(let redirects=0;redirects<=5;redirects++){
   const cooldown=this.cooldowns.get(u.hostname)||0;if(this.now()<cooldown)throw new ArtworkUnavailable(cooldown-this.now(),{attempted:false});
   // One request at a time and at least 1.1 s between starts, across providers.
   const delay=this.lastRequest+1100-this.now();if(delay>0)await this.wait(delay);this.lastRequest=this.now();
   let r;this.requests++;try{r=await this.fetch(u,{headers:{'User-Agent':this.userAgent},redirect:'manual',signal:AbortSignal.timeout(20000)});}catch{this.cooldowns.set(u.hostname,this.now()+60000);throw new ArtworkUnavailable();}
   if([301,302,303,307,308].includes(r.status)){await r.body?.cancel();const next=new URL(r.headers.get('location'),u);if(next.protocol==='http:'&&(next.hostname==='coverartarchive.org'||next.hostname==='archive.org'||/^(ia|dn)[0-9]+\.[a-z0-9-]+\.archive\.org$/.test(next.hostname)))next.protocol='https:';u=allowed(next);continue;}
   if(r.status===404){await r.body?.cancel();return null;}
   if(!r.ok){await r.body?.cancel();const h=r.headers.get('retry-after'),seconds=Number(h);const delay=Number.isFinite(seconds)&&seconds>0?seconds*1000:h&&Number.isFinite(Date.parse(h))?Date.parse(h)-this.now():60000;const until=this.now()+Math.max(60000,Math.min(delay,3600000));this.cooldowns.set(u.hostname,until);throw new ArtworkUnavailable(until-this.now());}
   if(Number(r.headers.get('content-length'))>max){await r.body?.cancel();throw Error('The artwork response is too large.');}
   let size=0;const chunks=[];for await(const chunk of r.body){size+=chunk.length;if(size>max){throw Error('The artwork response is too large.');}chunks.push(chunk);}return {bytes:Buffer.concat(chunks),type:r.headers.get('content-type')};
  }
  throw Error('The artwork provider redirected too many times.');
 }
 async json(url){const r=await this.response(url);if(!r)return null;try{return JSON.parse(r.bytes.toString());}catch{throw new ArtworkUnavailable();}}
 async image(url,source){const r=await this.response(url,MAX_IMAGE);if(!r)return null;const dimensions=await this.inspect(r.bytes,{directory:this.directory});return {...dimensions,bytes:r.bytes,source};}
 async find(identity,sourceUrls=[]){
  const before=this.requests+this.catalog.youtubeRequests;
  let unavailable;
  for(const url of [...new Set(sourceUrls)].slice(0,3)){
   let u;try{u=allowed(url);}catch{continue;}if(u.hostname!=='i.scdn.co')continue;
   try{const image=await this.image(u,'Spotify');if(image)return image;}catch(e){if(e instanceof ArtworkUnavailable)unavailable=e;}
  }
  if(!normalized(identity.album)||!identity.artists.length||GENERIC.has(normalized(identity.album)))return null;
  try{const image=await this.musicBrainz(identity);if(image)return image;}catch(e){if(e instanceof ArtworkUnavailable)unavailable=e;else throw e;}
  try{const image=await this.catalog.find(identity);if(image)return image;}catch(e){
   const next=e instanceof ArtworkUnavailable?e:new ArtworkUnavailable(e.retryAfter);
   if(!unavailable||next.attempted)unavailable=next;
  }
  if(unavailable){unavailable.attempted=this.requests+this.catalog.youtubeRequests>before;throw unavailable;}
  return null;
 }
 async musicBrainz(identity){
  const candidates=[];const id=identity.providerIds?.MusicBrainzReleaseGroup;
  if(UUID.test(id||'')){const group=await this.json(`https://musicbrainz.org/ws/2/release-group/${id}?inc=artist-credits&fmt=json`);if(group&&sameAlbum(group,identity))candidates.push(group);}
  const query=`releasegroup:"${normalized(identity.album)}" AND artist:"${normalized(identity.artists[0])}"`;
  if(!candidates.length){const u=new URL('https://musicbrainz.org/ws/2/release-group/');u.search=new URLSearchParams({query,fmt:'json',limit:'10'});const results=await this.json(u);candidates.push(...(results?.['release-groups']||[]).filter(x=>sameAlbum(x,identity)));}
  for(const group of candidates.slice(0,3)){
   if(!UUID.test(group.id||''))continue;
   const art=await this.json(`https://coverartarchive.org/release-group/${group.id}`);const cover=art?.images?.find(i=>i.front===true&&i.approved!==false);if(!cover)continue;
   // Prefer the original image. If a huge original is unsuitable, use the
   // archive's 1200 px copy. Neither path touches the song's audio stream.
   for(const url of [...new Set([cover.image,cover.thumbnails?.['1200']].filter(Boolean))]){
    try{const image=await this.image(url,'Cover Art Archive');if(image)return {...image,releaseGroup:group.id};}catch(e){if(e instanceof ArtworkUnavailable)throw e;}
   }
  }
  return null;
 }
}
export class ArtworkWorker{
 constructor({store,jellyfin,search,now=Date.now}){Object.assign(this,{store,jellyfin,search,now});this.running=false;store.data.artwork??={entries:{},runs:{}};this.data=store.data.artwork;for(const e of Object.values(this.data.entries))if(e.status==='searching')e.status='queued';for(const r of Object.values(this.data.runs))if(r.status==='scanning')r.status='queued';}
 owner(id){return {...this.store.owner(id),id};}
 request(owner){if(!owner.admin){const e=Error('A Jellyfin administrator can save missing library artwork.');e.status=403;throw e;}const current=this.data.runs[owner.id];if(current&&['queued','scanning','searching'].includes(current.status))return;this.data.runs[owner.id]={status:'queued',startedAt:this.now()};this.store.save();}
 enqueue(owner,albumId,songs=[],job=null,reset=false){const key=owner+':'+albumId;const entry=this.data.entries[key]??{owner,albumId,status:'queued',songIds:[],jobIds:[],sourceUrls:[]};entry.songIds=[...new Set([...entry.songIds,...songs.map(s=>s.Id)])];if(job){entry.jobIds=[...new Set([...entry.jobIds,job.id])];if(job.artwork){const fresh=!entry.sourceUrls.includes(job.artwork);entry.sourceUrls=[...new Set([...entry.sourceUrls,job.artwork])];if(fresh&&['noMatch','failed'].includes(entry.status)){entry.status='queued';entry.attempts=0;entry.nextAttempt=0;entry.error=null;}}}if(reset&&!['queued','searching'].includes(entry.status)){entry.status='queued';entry.attempts=0;entry.nextAttempt=0;entry.error=null;}this.data.entries[key]=entry;return entry;}
 async discover(owner){const songs=await this.jellyfin.songs(owner,true);for(const entry of Object.values(this.data.entries).filter(e=>e.owner===owner.id)){const matching=songs.filter(s=>s.AlbumId===entry.albumId);if(!matching.length){entry.status='removed';entry.error=null;}else if(matching.every(s=>s.ImageTags?.Primary||s.AlbumPrimaryImageTag)){if(entry.status!=='found')entry.status='existing';entry.error=null;}}for(const s of songs)if(s.AlbumId&&!s.ImageTags?.Primary&&!s.AlbumPrimaryImageTag)this.enqueue(owner.id,s.AlbumId,songs.filter(t=>t.AlbumId===s.AlbumId),null,true);}
 async process(entry){const owner=this.owner(entry.owner);try{
  entry.status='searching';entry.attempts=(entry.attempts||0)+1;this.store.save();
  const album=await this.jellyfin.item(owner,entry.albumId);if(album.Type!=='MusicAlbum')throw Error('This item is no longer a music album.');entry.album=album.Name;const songs=(await this.jellyfin.songs(owner)).filter(s=>s.AlbumId===entry.albumId);const identity=albumIdentity(album,songs);entry.artists=identity.artists;
  if(album.ImageTags?.Primary){entry.status='existing';entry.error=null;return;}
  if(!owner.admin)throw Error('A Jellyfin administrator can save missing library artwork.');
  const knownJobs=Object.values(this.store.data.jobs).filter(j=>j.owner===entry.owner&&j.artwork&&songs.some(song=>song.Id===j.itemId||normalized(j.album)===normalized(identity.album)&&trackKey({title:song.Name,artists:song.Artists||[]})===trackKey(j)));
  for(const job of knownJobs)this.enqueue(entry.owner,entry.albumId,songs,job);
  const image=await this.search.find(identity,entry.sourceUrls);if(!image){entry.status='noMatch';entry.error=GENERIC.has(normalized(identity.album))?'This folder mixes singles. Add album tags to find the right cover for each song.':'No confident album and artist match with a cover was found.';return;}
  const saved=await this.jellyfin.saveMissingCover(owner,entry.albumId,image);entry.status=saved?'found':'existing';entry.source=image.source;entry.width=image.width;entry.height=image.height;entry.releaseGroup=image.releaseGroup;entry.matchedAlbum=image.matchedAlbum;entry.sourceUrl=image.sourceUrl;entry.error=null;
 }catch(e){if(e instanceof ArtworkUnavailable&&!e.attempted)entry.attempts--;entry.error=e.message;entry.status=e instanceof ArtworkUnavailable&&entry.attempts<3?'queued':'failed';entry.nextAttempt=this.now()+(e.retryAfter||60000);}finally{entry.updatedAt=this.now();for(const id of entry.jobIds){const job=this.store.data.jobs[id];if(job)job.artworkStatus=entry.status;}this.store.save();}}
 summary(owner){const entries=Object.values(this.data.entries).filter(e=>e.owner===owner);return {canManage:this.store.owner(owner)?.admin===true,status:this.data.runs[owner]?.status||'idle',error:this.data.runs[owner]?.error||null,queued:entries.filter(e=>['queued','searching'].includes(e.status)).length,found:entries.filter(e=>e.status==='found').length,existing:entries.filter(e=>e.status==='existing').length,missing:entries.filter(e=>e.status==='noMatch').length,failed:entries.filter(e=>e.status==='failed').length,entries:entries.map(({owner:_,sourceUrls:__,jobIds:___,...e})=>e)};}
 async tick(){if(this.running)return;this.running=true;try{
  // New and already completed gaze imports get one artwork attempt. This loop
  // reads local state only; it never checks Spotify playlist updates.
  for(const job of Object.values(this.store.data.jobs))if(job.status==='ready'&&job.itemId&&!job.artworkQueued){try{const owner=this.owner(job.owner),song=await this.jellyfin.item(owner,job.itemId);if(song.ImageTags?.Primary||song.AlbumPrimaryImageTag){job.artworkStatus='existing';}else if(song.AlbumId)this.enqueue(job.owner,song.AlbumId,[song],job);job.artworkQueued=true;this.store.save();}catch{break;}}
  for(const [id,r] of Object.entries(this.data.runs))if(r.status==='queued'){r.status='scanning';this.store.save();try{await this.discover(this.owner(id));r.status='searching';r.error=null;}catch(e){r.status='failed';r.error=e.message;}this.store.save();}
  const entry=Object.values(this.data.entries).find(e=>e.status==='queued'&&(!e.nextAttempt||e.nextAttempt<=this.now()));if(entry)await this.process(entry);
  for(const [id,r] of Object.entries(this.data.runs))if(r.status==='searching'&&!Object.values(this.data.entries).some(e=>e.owner===id&&['queued','searching'].includes(e.status))){r.status='complete';r.finishedAt=this.now();this.store.save();}
 }finally{this.running=false;}}
}
