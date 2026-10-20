import test from 'node:test';
import assert from 'node:assert/strict';
import {CatalogArtwork,coverMatchScore} from '../catalog-artwork.js';
import {ArtworkSearch,ArtworkUnavailable,ArtworkWorker} from '../artwork.js';

const identity={album:'Song',artists:['Artist'],songs:[{title:'Song',artists:['Artist'],duration:180}]};
const cover={title:'Song',artists:['Artist'],album:'Actual Album',duration:181,image:'https://yt3.googleusercontent.com/cover=w600-h600',source:'YouTube Music'};
const json=value=>new Response(JSON.stringify(value));
const image={bytes:Buffer.from('validated'),type:'image/jpeg',width:600,height:600};

test('a song-named single can find its actual release, with exact title and artist',()=>{
 assert(coverMatchScore(cover,identity)>0);
 assert.equal(coverMatchScore({...cover,artists:['Impersonator']},identity),0);
 assert.equal(coverMatchScore({...cover,title:'Song (Live)'},identity),0);
 assert.equal(coverMatchScore({...cover,title:'Song (Remix)'},identity),0);
 assert.equal(coverMatchScore({...cover,duration:240},identity),0);
 assert.equal(coverMatchScore({...cover,album:'Song',duration:240},identity),0);
 assert.equal(coverMatchScore(cover,{...identity,album:'Real Album'}),0);
 assert.equal(coverMatchScore(cover,{...identity,songs:[...identity.songs,...identity.songs]}),0);
 assert(coverMatchScore({...cover,album:'Song - Single'},identity)>coverMatchScore(cover,identity));
});
test('real album matches preserve edition and credit requirements',()=>{
 const album={album:'Actual Album (Deluxe)',artists:['Artist'],songs:[]};
 assert(coverMatchScore({...cover,album:album.album},album)>0);
 assert.equal(coverMatchScore(cover,album),0);
 assert.equal(coverMatchScore({...cover,album:album.album,artists:['Wrong Artist']},album),0);
});
test('featured credits and imported legal aliases need a corroborating match',()=>{
 const featured={...identity,artists:['Artist, Guest'],songs:[{title:'Song',artists:['Artist, Guest'],duration:180}]};
 assert(coverMatchScore({...cover,title:'Song (feat. Guest)'},featured)>0);
 assert.equal(coverMatchScore({...cover,title:'Song',duration:120},featured),0);
 const alias={...identity,artists:['Artist, Legal Name'],songs:[{title:'Song',artists:['Artist, Legal Name'],duration:180}]};
 assert(coverMatchScore(cover,alias)>0);
 assert.equal(coverMatchScore({...cover,duration:0},alias),0);
 assert.equal(coverMatchScore({...cover,duration:187},alias),0);
});
test('Apple Music matches use a validated large cover before YouTube Music',async()=>{
 let youtube=0;
 const catalog=new CatalogArtwork({youtube:async()=>{youtube++;return [];},search:{now:()=>100000,wait:async()=>{},json:async url=>{assert.equal(url.hostname,'itunes.apple.com');assert.equal(url.searchParams.get('term'),'Artist Song');return {results:[{kind:'song',trackName:'Song',artistName:'Artist',collectionName:'Actual Album',trackTimeMillis:180000,artworkUrl100:'https://is1-ssl.mzstatic.com/image/100x100bb.jpg'}]};},image:async(url,source)=>{assert.equal(url,'https://is1-ssl.mzstatic.com/image/600x600bb.jpg');return {...image,source};}}});
 const result=await catalog.find(identity);assert.equal(result.source,'Apple Music');assert.equal(result.matchedAlbum,'Actual Album');assert.equal(youtube,0);
});
test('YouTube Music can recover a cover even when both earlier catalogs fail',async()=>{
 const calls=[];
 const search=new ArtworkSearch({now:()=>100000,wait:async()=>{},inspect:async()=>image,youtube:async()=>[cover],fetchImpl:async url=>{calls.push(url.hostname);return url.hostname==='yt3.googleusercontent.com'?new Response('validated'):new Response('',{status:503});}});
 assert.equal((await search.find(identity)).source,'YouTube Music');assert.deepEqual(calls,['musicbrainz.org','itunes.apple.com','yt3.googleusercontent.com']);
});
test('provider cooldowns do not reset their deadline or count nonexistent attempts',async()=>{
 let time=100000,youtube=0,requests=0;
 const search=new ArtworkSearch({now:()=>time,wait:async()=>{},youtube:async()=>{youtube++;throw Error('offline');},fetchImpl:async()=>{requests++;return new Response('',{status:503});}});
 await assert.rejects(search.find(identity),error=>error instanceof ArtworkUnavailable&&error.attempted);
 assert.equal(requests,2);assert.equal(youtube,1);
 const deadline=search.catalog.youtubeRetryAt;
 time+=10000;
 await assert.rejects(search.find(identity),error=>error instanceof ArtworkUnavailable&&!error.attempted);
 assert.equal(search.catalog.youtubeRetryAt,deadline);assert.equal(requests,2);assert.equal(youtube,1);
 time+=60001;
 await assert.rejects(search.find(identity),error=>error.attempted);assert.equal(youtube,2);assert.equal(requests,4);
});
test('an artwork worker keeps its retry budget while providers are cooling down',async()=>{
 const store={data:{owners:{owner:{admin:true}},jobs:{}},owner:()=>({admin:true}),save:()=>{}};
 const worker=new ArtworkWorker({store,jellyfin:{item:async()=>({Type:'MusicAlbum',Name:'Song',Artists:['Artist']}),songs:async()=>[]},search:{find:async()=>{throw new ArtworkUnavailable(60000,{attempted:false});}}});
 const entry=worker.enqueue('owner','album');entry.attempts=2;
 await worker.process(entry);assert.equal(entry.attempts,2);assert.equal(entry.status,'queued');
});
test('new catalog image addresses still reject redirects outside known cover hosts',async()=>{
 const search=new ArtworkSearch({wait:async()=>{},fetchImpl:async()=>new Response(null,{status:302,headers:{location:'https://attacker.example/cover'}})});
 await assert.rejects(search.image('https://yt3.googleusercontent.com/cover','YouTube Music'),/Unsupported artwork provider/);
});
test('a clean Apple edition waits for a matching standard release cover',async()=>{
 const catalog=new CatalogArtwork({youtube:async()=>[cover],search:{now:()=>100000,wait:async()=>{},json:async()=>({results:[{kind:'song',trackName:'Song',artistName:'Artist',collectionName:'Actual Album',trackTimeMillis:180000,trackExplicitness:'cleaned',artworkUrl100:'https://is1-ssl.mzstatic.com/image/100x100bb.jpg'}]}),image:async(_,source)=>({...image,source})}});
 assert.equal((await catalog.find(identity)).source,'YouTube Music');
});
