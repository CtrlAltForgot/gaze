import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {ArtworkSearch,ArtworkWorker,ArtworkUnavailable,albumIdentity,sameAlbum,imageDetails} from '../artwork.js';
import {Store} from '../store.js';
import {Jellyfin} from '../jellyfin.js';
const albumId='a'.repeat(32),songId='b'.repeat(32);
const identity={album:'Album (Live)',artists:['Artist'],providerIds:{}};
const group={id:'12345678-1234-1234-1234-123456789abc',title:'Album (Live)','artist-credit':[{name:'Artist'}]};
const png=Buffer.from([137,80,78,71,13,10,26,10,1]);
const image={bytes:png,type:'image/png',width:640,height:640,source:'Spotify'};
const response=(value)=>new Response(JSON.stringify(value),{headers:{'content-type':'application/json'}});
function search(options){return new ArtworkSearch({now:()=>100000,wait:async()=>{},youtube:async()=>[],inspect:async()=>({type:'image/png',width:640,height:640}),...options});}
function fixture(fn){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gaze-artwork-'));const store=new Store(dir);store.data.owners.owner={admin:true,token:'test'};return Promise.resolve().then(()=>fn(store,dir)).finally(()=>fs.rmSync(dir,{recursive:true,force:true}));}
test('album search keeps artist and edition exact and can use the old artist folder',()=>{
 assert(sameAlbum(group,identity));assert(!sameAlbum({...group,title:'Album'},identity));assert(!sameAlbum({...group,'artist-credit':[{name:'Someone Else'}]},identity));
 assert.deepEqual(albumIdentity({Name:'Album',Path:'/music/Artist/Album'}).artists,['Artist']);
 assert.deepEqual(albumIdentity({Name:'Album',AlbumArtists:[{Name:'Tagged Artist'}],Path:'/music/Wrong/Album'}).artists,['Tagged Artist']);
});
test('saved source artwork is tried before any catalog search, without a Spotify API request',async()=>{
 const calls=[];const s=search({fetchImpl:async u=>{calls.push(String(u));return new Response(png);}});
 assert.equal((await s.find(identity,['https://i.scdn.co/image/cover'])).source,'Spotify');assert.deepEqual(calls,['https://i.scdn.co/image/cover']);
});
test('catalog requires matching album and artist and selects only a front cover',async()=>{
 const calls=[];const s=search({fetchImpl:async u=>{calls.push(String(u));if(u.hostname==='musicbrainz.org')return response({'release-groups':[{...group,'artist-credit':[{name:'Wrong Artist'}]},group]});if(u.hostname==='coverartarchive.org')return response({images:[{front:false,image:'https://archive.org/back.png'},{front:true,image:'https://archive.org/front.png'}]});return new Response(png);}});
 const result=await s.find(identity,['https://i.ytimg.com/video.jpg']);assert.equal(result.source,'Cover Art Archive');assert(calls.at(-1).endsWith('/front.png'));assert(!calls.some(u=>u.includes('ytimg')));
});
test('incorrect artist result is unresolved and never downloads its image',async()=>{
 const s=search({fetchImpl:async()=>response({'release-groups':[{...group,'artist-credit':[{name:'Wrong Artist'}]}]})});assert.equal(await s.find(identity),null);
});
test('redirects cannot escape the provider allowlist and image sizes are bounded',async()=>{
 await assert.rejects(search({fetchImpl:async()=>new Response(null,{status:307,headers:{location:'http://127.0.0.1/secret'}})}).find(identity,['https://i.scdn.co/image/cover']),/unavailable|address|provider/);
 const s=search({fetchImpl:async()=>new Response(new Uint8Array(20))});await assert.rejects(s.response('https://i.scdn.co/image/cover',10),/too large/);
});
test('provider throttling honors cooldown instead of polling every tick',async()=>{
 let count=0,time=100000;const s=search({now:()=>time,fetchImpl:async()=>{count++;return new Response('',{status:429,headers:{'retry-after':'120'}});}});
 await assert.rejects(s.find(identity,['https://i.scdn.co/image/cover']),e=>e.retryAfter===120000);
 await assert.rejects(s.find(identity,['https://i.scdn.co/image/cover']),ArtworkUnavailable);assert.equal(count,3);time+=120001;
 await assert.rejects(s.find(identity,['https://i.scdn.co/image/cover']),ArtworkUnavailable);assert.equal(count,6);
});
test('image validation uses real image dimensions and rejects HTML, tiny images and video-shaped covers',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gaze-image-'));try{
  for(const [size,ok] of [['640x640',true],['50x50',false],['640x360',false]]){const file=path.join(dir,'test.png');execFileSync('ffmpeg',['-v','error','-y','-f','lavfi','-i',`color=c=blue:s=${size}`,'-frames:v','1',file]);const inspect=()=>imageDetails(fs.readFileSync(file),{directory:dir});if(ok)assert.equal((await inspect()).width,640);else await assert.rejects(inspect(),/suitable/);}
  await assert.rejects(imageDetails(Buffer.from('<html>not artwork</html>')),/unsupported/);assert(!fs.readdirSync(dir).some(p=>p.startsWith('gaze-cover-')));
 }finally{fs.rmSync(dir,{recursive:true});}
});
test('fresh cover check preserves artwork added while an external search was running',async()=>{
 let posts=0;const jellyfin=new Jellyfin('http://music.local',{fetchImpl:async(u,options)=>{if(options.method==='POST'){posts++;assert.fail('existing cover overwritten');}return response({Id:albumId,Type:'MusicAlbum',ImageTags:{Primary:'existing'}});}});
 assert.equal(await jellyfin.saveMissingCover({id:'owner',token:'t'},albumId,image),false);assert.equal(posts,0);
});
test('Jellyfin upload sends base64 image bytes and confirms the new tag',async()=>{
 let saved=false;const jf=new Jellyfin('http://music.local',{fetchImpl:async(u,options)=>{if(options.method==='POST'){assert.equal(u.pathname,`/Items/${albumId}/Images/Primary`);assert.equal(options.headers['content-type'],'image/png');assert.equal(options.body,png.toString('base64'));saved=true;return new Response(null,{status:204});}return response({Id:albumId,Type:'MusicAlbum',ImageTags:saved?{Primary:'new'}:{}});}});
 assert.equal(await jf.saveMissingCover({id:'owner',token:'t'},albumId,image),true);
});
test('album queue coalesces songs; artwork failures never affect ready audio or playlist state',()=>fixture(async store=>{
 const job=store.add('owner',{title:'Song',artists:['Artist']});Object.assign(job,{status:'ready',itemId:songId,relative:'original.opus',quality:{originalAudio:true}});
 const worker=new ArtworkWorker({store,jellyfin:{item:async()=>({Type:'MusicAlbum',Name:'Album',AlbumArtists:[{Name:'Artist'}],ImageTags:{}}),songs:async()=>[]},search:{find:async()=>{throw new ArtworkUnavailable(60000);}}});
 const entry=worker.enqueue('owner',albumId,[{Id:songId}],job);worker.enqueue('owner',albumId,[{Id:'c'.repeat(32)}],job);assert.equal(Object.keys(worker.data.entries).length,1);assert.equal(entry.songIds.length,2);
 await worker.process(entry);assert.equal(entry.status,'queued');assert.equal(job.status,'ready');assert.equal(job.relative,'original.opus');assert.equal(job.error,null);assert.equal(job.quality.originalAudio,true);
 await worker.process(entry);await worker.process(entry);assert.equal(entry.status,'failed');assert.equal(entry.attempts,3);
}));
test('manual library scan searches only missing albums and checks administrator permission',()=>fixture(async store=>{
 let searched=0;const worker=new ArtworkWorker({store,jellyfin:{songs:async()=>[{Id:songId,AlbumId:albumId},{Id:'c',AlbumId:'covered',AlbumPrimaryImageTag:'keep'}],item:async()=>({Type:'MusicAlbum',Name:'Album',AlbumArtists:[{Name:'Artist'}],ImageTags:{}})},search:{find:async()=>{searched++;return null;}}});
 assert.throws(()=>worker.request({id:'owner',admin:false}),/administrator/);worker.request({id:'owner',admin:true});await worker.tick();assert.equal(searched,1);assert.equal(Object.keys(worker.data.entries).length,1);assert.equal(worker.summary('owner').status,'complete');assert.equal(worker.summary('owner').missing,1);
 await worker.tick();assert.equal(searched,1);worker.request({id:'owner',admin:true});await worker.tick();assert.equal(searched,2);assert.equal(worker.summary('another').entries.length,0);
}));
test('completed imports get artwork independently and restart resumes the search without audio download',()=>fixture(async store=>{
 const job=store.add('owner',{title:'Song',artists:['Artist'],artwork:'https://i.scdn.co/image/cover'});Object.assign(job,{status:'ready',itemId:songId});let saved=0;
 const jf={item:async(_,id)=>id===songId?{Id:songId,AlbumId:albumId}:{Id:albumId,Name:'Album',Type:'MusicAlbum',AlbumArtists:[{Name:'Artist'}],ImageTags:{}},songs:async()=>[],saveMissingCover:async()=>{saved++;return true;}};
 const worker=new ArtworkWorker({store,jellyfin:jf,search:{find:async()=>image}});await worker.tick();await worker.tick();assert.equal(saved,1);assert.equal(job.status,'ready');assert.equal(job.artworkStatus,'found');
 worker.data.entries['owner:'+albumId].status='searching';store.save();const recovered=new ArtworkWorker({store,jellyfin:jf,search:{find:async()=>image}});assert.equal(recovered.data.entries['owner:'+albumId].status,'queued');assert.equal(job.status,'ready');
}));

test('Cover Art Archive can follow its verified Internet Archive CDN redirects',async()=>{
 const calls=[];const s=search({fetchImpl:async u=>{calls.push(u.hostname);if(u.hostname==='coverartarchive.org')return new Response(null,{status:307,headers:{location:'http://archive.org/download/cover.jpg'}});if(u.hostname==='archive.org')return new Response(null,{status:302,headers:{location:'https://dn710104.ca.archive.org/cover.jpg'}});assert.equal(u.protocol,'https:');return new Response(png);}});
 assert.equal((await s.image('https://coverartarchive.org/front.jpg','Cover Art Archive')).width,640);assert.deepEqual(calls,['coverartarchive.org','archive.org','dn710104.ca.archive.org']);
});

test('MusicBrainz cooldown does not prevent using a saved Spotify cover',async()=>{
 const calls=[];const s=search({fetchImpl:async u=>{calls.push(u.hostname);return u.hostname==='musicbrainz.org'?new Response('',{status:503}):new Response(png);}});
 await assert.rejects(s.find(identity),ArtworkUnavailable);assert.equal((await s.find(identity,['https://i.scdn.co/image/cover'])).source,'Spotify');assert.deepEqual(calls,['musicbrainz.org','itunes.apple.com','i.scdn.co']);
});
test('manual repair can use identified source artwork for indexed songs still awaiting import confirmation',()=>fixture(async store=>{
 const job=store.add('owner',{title:'Song',artists:['Artist'],album:'Album (Live)',artwork:'https://i.scdn.co/image/cover'});job.status='scanning';
 const worker=new ArtworkWorker({store,jellyfin:{item:async()=>({Id:albumId,Type:'MusicAlbum',Name:'Album (Live)',AlbumArtists:[{Name:'Artist'}],ImageTags:{}}),songs:async()=>[{Id:songId,AlbumId:albumId,Name:'Song',Artists:['Artist']}],saveMissingCover:async()=>true},search:{find:async(_,urls)=>{assert.deepEqual(urls,[job.artwork]);return image;}}});
 const entry=worker.enqueue('owner',albumId,[{Id:songId}]);await worker.process(entry);assert.equal(entry.status,'found');assert.equal(job.status,'scanning');
}));

test('a confirmed import item retains its source cover when Jellyfin changes artist or album display metadata',()=>fixture(async store=>{
 const job=store.add('owner',{title:'Song',artists:['Original artist'],album:'Original album',artwork:'https://i.scdn.co/image/cover'});Object.assign(job,{status:'ready',itemId:songId});
 const worker=new ArtworkWorker({store,jellyfin:{item:async()=>({Id:albumId,Type:'MusicAlbum',Name:'Catalog album name',AlbumArtists:[{Name:'Various Artists'}],ImageTags:{}}),songs:async()=>[{Id:songId,AlbumId:albumId,Name:'Catalog song name',Artists:['Catalog artist']}],saveMissingCover:async()=>true},search:{find:async(_,urls)=>{assert.deepEqual(urls,[job.artwork]);return image;}}});
 const entry=worker.enqueue('owner',albumId,[{Id:songId}]);await worker.process(entry);assert.equal(entry.status,'found');assert.equal(job.status,'ready');
}));
