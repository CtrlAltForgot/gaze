import test from 'node:test';
import assert from 'node:assert/strict';
import {ArtistArtworkWorker,artistMatches} from '../artist-artwork.js';
const image={bytes:Buffer.from('image'),type:'image/jpeg',width:600,height:600};
function fixture({name='Artist',candidates=async()=>[{name:'Artist',image:'cover',source:'YouTube Music artist'}],existing=false}={}){
 const store={data:{owners:{owner:{admin:true}},jobs:{song:{status:'ready'}}},owner:()=>({admin:true}),save:()=>{}};
 const saved=[];const artist={Id:'artist',Type:'MusicArtist',Name:name,ImageTags:existing?{Primary:'keep'}:{}};
 const jf={item:async()=>artist,artists:async()=>[artist],songs:async()=>[{Id:'song',Name:'Song',Artists:[name],ArtistItems:[{Id:'artist',Name:name}],AlbumId:'album',AlbumPrimaryImageTag:'cover'}],libraryImage:async()=>image,saveMissingArtistImage:async(_,id,img)=>{saved.push({id,image:img});return true;}};
 const worker=new ArtistArtworkWorker({store,jellyfin:jf,candidates,inspect:async()=>image,search:{wait:async()=>{},image:async(_,source)=>({...image,source})}});
 return {worker,saved,store};
}
test('artist identity matches whole credits or Jellyfin artist IDs, never substrings',()=>{
 assert(artistMatches({Id:'id',Name:'Artist'},{ArtistItems:[{Id:'id'}]}));
 assert(artistMatches({Id:'id',Name:'$crim'},{Artists:['Scrim']}));
 assert(!artistMatches({Id:'id',Name:'Artist'},{Artists:['Another Artist']}));
});
test('artist recovery saves matched portraits without changing ready music',async()=>{
 const {worker,saved,store}=fixture();await worker.tick();assert.equal(saved[0].image.source,'YouTube Music artist');assert.equal(store.data.jobs.song.status,'ready');assert.equal(Object.values(worker.data.entries)[0].status,'found');
});
test('existing artist images are preserved',async()=>{
 const {worker,saved}=fixture({existing:true});await worker.tick();assert.equal(saved.length,0);
});
test('combined credits use only artwork from their shared music',async()=>{
 const {worker,saved}=fixture({name:'Artist; Guest',candidates:async()=>assert.fail('Combined credit sent as a person')});await worker.tick();assert.equal(saved[0].image.source,'Library release artwork');assert.equal(Object.values(worker.data.entries)[0].status,'fallback');
});
test('wrong catalog artist is rejected and a library release can still supply artwork',async()=>{
 const {worker,saved}=fixture({candidates:async()=>[{name:'Different Artist',image:'wrong'}]});await worker.tick();assert.equal(saved[0].image.source,'Library release artwork');
});
test('catalog outages preserve library fallback and initiate a cooldown',async()=>{
 const {worker,saved}=fixture({candidates:async()=>{throw Error('offline');}});await worker.tick();assert.equal(saved[0].image.source,'Library release artwork');assert(worker.catalogRetryAt>Date.now());
});
