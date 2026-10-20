import fs from 'node:fs';
import path from 'node:path';
import {spotifyTrack} from './spotify.js';
import {youtubeUrl} from './store.js';
import {knownYoutubeSource,recoverSynoptiSources} from './synopti-source.js';
export class Worker{
 constructor({store,jellyfin,spotify,resolve,download,feedDirectory,guildId,settingsFile}){Object.assign(this,{store,jellyfin,spotify,resolve,download,feedDirectory,guildId,settingsFile});this.running=false;}
 owner(id){const owner=this.store.owner(id);if(!owner)throw Error('This gaze account is not connected.');return {...owner,id};}
 async importSource(owner,id){if(!/^[A-Za-z0-9]{22}$/.test(id))throw Error('Choose a valid Spotify playlist.');const key=owner.id+':'+id;const source=this.store.data.sources[key]??{id,owner:owner.id,name:'Spotify playlist',enabled:true,jobIds:[],unavailable:0,nextSync:0};this.store.data.sources[key]=source;source.requested=true;source.enabled=true;this.store.save();return source;}
 async syncSource(source){try{const owner=this.owner(source.owner),snapshot=await this.spotify.snapshot(owner.id,source.id);const tracks=snapshot.items.map(spotifyTrack),ids=tracks.map((t,index)=>{if(t)return this.store.add(owner.id,t).id;const job=this.store.add(owner.id,{title:`Unavailable entry ${index+1} in ${snapshot.name}`,artists:['Unknown artist'],kind:'Spotify',unidentified:true,sourcePlaylist:source.id,sourcePosition:index+1});if(job.status==='queued'){job.status='needsMatch';job.error='Spotify did not provide song metadata. Enter the song title, artist, and exact YouTube link.';}return job.id;});source.name=snapshot.name;source.snapshot=snapshot.snapshot;source.jobIds=ids;source.unavailable=0;source.lastSync=Date.now();source.syncMode='manual';source.nextSync=null;source.requested=false;source.error=null;source.dirty=true;this.store.save();}catch(e){source.error=e.message;source.nextSync=null;source.requested=false;this.store.save();}}
 ingest(){
  if(!this.feedDirectory||!fs.existsSync(this.feedDirectory))return;
  const ownerId=this.store.data.botOwner,owner=ownerId&&this.store.owner(ownerId);if(!owner?.botEnabled)return;
  for(const file of fs.readdirSync(this.feedDirectory).filter(f=>/^[a-f0-9-]+\.json$/.test(f)).sort()){
   const eventKey=file.slice(0,-5);if(this.store.data.events[eventKey])continue;
   let event;try{event=JSON.parse(fs.readFileSync(path.join(this.feedDirectory,file),'utf8'));}catch{continue;}if(event.guildId!==this.guildId)continue;
   const t=event.track;if(!t?.title)continue;const source=knownYoutubeSource(t.youtubeUrl);if(source&&(owner.ignoredYoutubeUrls||[]).includes(source)){this.store.data.events[eventKey]=Date.now();this.store.save();continue;}
   const unidentified=!t.artists?.length;
   const job=this.store.add(ownerId,{...t,artists:unidentified?['Unknown artist']:t.artists,kind:'Synopti',unidentified,youtubeUrl:source,sourceConfirmed:!!source});
   if(unidentified&&!source&&job.status==='queued'){job.status='needsMatch';job.error='Synopti did not report a valid YouTube source for this entry. Choose its recording.';}
   owner.lastEventAt=event.playedAt;owner.botError=null;this.store.data.events[eventKey]=Date.now();this.store.save();
  }
 }
 async process(job){const owner=this.owner(job.owner);try{
  const existing=await this.jellyfin.find(owner,job,{relative:job.relative});
  if(existing){job.itemId=existing.Id;job.status='ready';job.reused=!job.relative;job.error=null;this.changed(job);return;}
  if(job.relative){job.status='scanning';if(!job.lastScan||Date.now()-job.lastScan>60000){await this.jellyfin.scan(owner,job.relative);job.lastScan=Date.now();}job.nextAttempt=Date.now()+15000;job.error='Saved at original quality. Waiting for Jellyfin to index the file.';this.changed(job);return;}
  if(!job.youtubeUrl){job.status='matching';this.changed(job);let matches={};try{matches=JSON.parse(fs.readFileSync(this.settingsFile,'utf8')).guilds?.[this.guildId]?.musicMatches||{};}catch{}
   try{const result=await this.resolve({spotifyTitle:job.title,spotifyArtists:job.artists,spotifyExplicit:job.explicit,spotifyIsrc:job.isrc,duration:job.duration,album:job.album,artwork:job.artwork},{matches});job.youtubeUrl=youtubeUrl(result.url);job.matchedTitle=result.matchedTitle||result.title;job.match=result.match||null;}catch{job.status='needsMatch';job.error='No confident match found. Paste the YouTube version you want.';this.changed(job);return;}
  }
  if((owner.ignoredYoutubeUrls||[]).includes(job.youtubeUrl)){job.status='ignored';job.error='This video was excluded from your library.';this.changed(job);return;}job.status='downloading';job.error=null;this.changed(job);const downloaded=await this.download(job);Object.assign(job,downloaded,{status:'scanning',nextAttempt:Date.now()+15000});this.changed(job);await this.jellyfin.scan(owner,job.relative);job.lastScan=Date.now();this.changed(job);
 }catch(e){job.status=job.relative?'scanning':'failed';job.error=e.message;job.nextAttempt=Date.now()+60000;this.changed(job);}}
 changed(job,{save=true}={}){job.updatedAt=Date.now();for(const s of Object.values(this.store.data.sources))if(s.owner===job.owner&&s.jobIds.includes(job.id))s.dirty=true;if(save)this.store.save();}
 async reconcileSaved(jobs){let changed=false;for(const ownerId of new Set(jobs.map(j=>j.owner))){try{const songs=await this.jellyfin.songs(this.owner(ownerId),true),paths=new Map(songs.filter(s=>s.Path).map(s=>[s.Path,s]));for(const job of jobs.filter(j=>j.owner===ownerId&&j.relative)){const item=paths.get(this.jellyfin.musicPath+'/'+job.relative.split('\\').join('/'));if(!item)continue;job.itemId=item.Id;job.status='ready';job.error=null;job.nextAttempt=0;this.changed(job,{save:false});changed=true;}}catch{/* Keep saved files pending when a complete library snapshot is unavailable. */}}if(changed)this.store.save();}
 async mirror(source){if(!source.enabled||!source.snapshot||!source.dirty)return;const ids=source.jobIds.map(id=>this.store.data.jobs[id]).filter(j=>j?.status==='ready').map(j=>j.itemId);try{await this.jellyfin.mirror(this.owner(source.owner),source,ids,()=>this.store.save());source.savedCount=new Set(ids).size;source.pendingCount=source.jobIds.filter(id=>this.store.data.jobs[id]?.status!=='ready').length+source.unavailable;source.mirrorError=null;source.dirty=false;source.lastSaved=Date.now();}catch(e){source.mirrorError=e.message;}this.store.save();}
 async tick(){if(this.running)return;this.running=true;try{this.ingest();recoverSynoptiSources(this.store);for(const s of Object.values(this.store.data.sources))if(s.enabled&&s.requested)await this.syncSource(s);const jobs=Object.values(this.store.data.jobs).filter(j=>['queued','scanning'].includes(j.status)&&(!j.nextAttempt||j.nextAttempt<Date.now())).sort((a,b)=>a.updatedAt-b.updatedAt);await this.reconcileSaved(jobs.filter(j=>j.status==='scanning'));const scanning=jobs.find(j=>j.status==='scanning');if(scanning)await this.process(scanning);const queued=jobs.find(j=>j.status==='queued');if(queued)await this.process(queued);for(const s of Object.values(this.store.data.sources))await this.mirror(s);}finally{this.running=false;}}
}
