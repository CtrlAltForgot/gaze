import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {normalized} from './store.js';
import {ArtworkUnavailable,imageDetails} from './artwork.js';
const execute=promisify(execFile);
const script=fileURLToPath(new URL('./youtube-artist-artwork.py',import.meta.url));
const key=value=>normalized(String(value||'').replace(/\$/g,'s'));
export const artistMatches=(artist,song)=>[...(song.ArtistItems||[]),...(song.AlbumArtists||[])].some(a=>a.Id===artist.Id)||(song.Artists||[]).some(name=>key(name)===key(artist.Name));
export async function artistCandidates(identity){
 const {stdout}=await execute('python3',[script,JSON.stringify(identity)],{timeout:60000,maxBuffer:512*1024});const result=JSON.parse(stdout);if(!Array.isArray(result))throw Error('Invalid artist catalog response.');return result;
}
export class ArtistArtworkWorker{
 constructor({store,jellyfin,search,candidates=artistCandidates,inspect=imageDetails,now=Date.now}){
  Object.assign(this,{store,jellyfin,search,candidates,inspect,now});this.running=false;this.inFlight=new Map();this.songSnapshots=new Map();this.catalogQueue=Promise.resolve();this.catalogRetryAt=0;this.catalogNextAt=0;this.discoveryAt=0;
  store.data.artistArtwork??={entries:{}};this.data=store.data.artistArtwork;
  for(const entry of Object.values(this.data.entries))if(entry.status==='searching')entry.status='queued';
 }
 async songs(owner){
  let saved=this.songSnapshots.get(owner.id);
  if(!saved||this.now()-saved.at>900000){saved={at:this.now(),promise:this.jellyfin.songs(owner)};this.songSnapshots.set(owner.id,saved);saved.promise.catch(()=>this.songSnapshots.delete(owner.id));}
  return saved.promise;
 }
 async discover(owner){
  const artists=await this.jellyfin.artists(owner);
  for(const artist of artists){
   const id=owner.id+':'+artist.Id;const old=this.data.entries[id];
   if(artist.ImageTags?.Primary){if(old&&!['found','fallback'].includes(old.status)){old.status='existing';old.error=null;}continue;}
   if(!old||(['failed','noMatch'].includes(old.status)&&this.now()-(old.updatedAt||0)>86400000))this.data.entries[id]={owner:owner.id,id:artist.Id,name:artist.Name,status:'queued',attempts:0};
  }
  this.store.save();
 }
 async process(entry){
  const owner={...this.store.owner(entry.owner),id:entry.owner};
  try{
   entry.status='searching';this.store.save();
   const artist=await this.jellyfin.item(owner,entry.id);if(artist.Type!=='MusicArtist')throw Error('This item is no longer an artist.');
   if(artist.ImageTags?.Primary){entry.status='existing';return;}
   const songs=(await this.songs(owner)).filter(song=>artistMatches(artist,song));
   let image;let unavailable=false;
   if(!artist.Name.includes(';')&&songs.length){
    if(this.now()<this.catalogRetryAt){unavailable=true;}
    else{
     try{
      const pending=this.catalogQueue.then(async()=>{
       const delay=this.catalogNextAt-this.now();if(delay>0)await this.search.wait(delay);
       this.catalogNextAt=this.now()+1500;
       return this.candidates({name:artist.Name,songs:[...new Set(songs.map(s=>s.Name))].slice(0,3)});
      });
      this.catalogQueue=pending.catch(()=>{});
      const candidates=await pending;
      for(const candidate of candidates.slice(0,3)){
       if(key(candidate.name)!==key(artist.Name))continue;
       image=await this.search.image(candidate.image,candidate.source);
       if(image){image.sourceUrl=candidate.sourceUrl;break;}
      }
     }catch{this.catalogRetryAt=this.now()+60000;unavailable=true;}
    }
   }
   // Combined credits have no standalone portrait. Use a real cover from
   // their shared library music, never an unrelated person's picture.
   if(!image){
    const covered=songs.find(s=>s.ImageTags?.Primary||s.AlbumPrimaryImageTag);
    if(covered){image=await this.jellyfin.libraryImage(owner,covered.ImageTags?.Primary?covered.Id:covered.AlbumId);if(image)image={...image,...await this.inspect(image.bytes),source:'Library release artwork'};}
   }
   if(!image){
    if(unavailable){entry.status='queued';entry.nextAttempt=this.now()+60000;return;}
    entry.status='noMatch';entry.error='No verified portrait or library cover was found.';return;
   }
   const saved=await this.jellyfin.saveMissingArtistImage(owner,entry.id,image);
   entry.status=saved?(image.source==='Library release artwork'?'fallback':'found'):'existing';entry.source=image.source;entry.sourceUrl=image.sourceUrl;entry.width=image.width;entry.height=image.height;entry.error=null;
  }catch(error){entry.attempts=(entry.attempts||0)+1;entry.status=entry.attempts<3?'queued':'failed';entry.nextAttempt=this.now()+60000;entry.error='Artist artwork could not be saved. It will be retried.';}
  finally{entry.updatedAt=this.now();this.store.save();}
 }
 async tick(){
  if(this.running)return;this.running=true;
  try{
   if(this.now()>=this.discoveryAt){this.discoveryAt=this.now()+3600000;for(const [id,owner] of Object.entries(this.store.data.owners))if(owner.admin)await this.discover({...owner,id});}
   const entries=Object.values(this.data.entries).filter(e=>e.status==='queued'&&(!e.nextAttempt||e.nextAttempt<=this.now())).slice(0,Math.max(0,4-this.inFlight.size));
   for(const entry of entries){const task=this.process(entry).finally(()=>this.inFlight.delete(entry.id));this.inFlight.set(entry.id,task);}
   if(this.inFlight.size)await Promise.race(this.inFlight.values());
  }finally{this.running=false;}
 }
}
