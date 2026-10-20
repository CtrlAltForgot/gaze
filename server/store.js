import fs from 'node:fs';
import path from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
export function normalized(value){return String(value||'').normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim();}
export function trackKey(track){return `${normalized(track.title)}\0${(track.artists||[]).map(normalized).filter(Boolean).sort().join('|')}`;}
export function jobId(owner,track){return createHash('sha256').update(owner+'\0'+trackKey(track)).digest('hex').slice(0,32);}
export function atomicJson(file,data){fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});const temp=file+'.'+randomUUID()+'.tmp';try{fs.writeFileSync(temp,JSON.stringify(data),{mode:0o600});const fd=fs.openSync(temp,'r');try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}fs.renameSync(temp,file);}finally{fs.rmSync(temp,{force:true});}}
export class Store{
 constructor(directory){this.directory=directory;this.file=path.join(directory,'state.json');this.data=fs.existsSync(this.file)?JSON.parse(fs.readFileSync(this.file,'utf8')):{version:1,owners:{},jobs:{},sources:{},events:{},botOwner:null};if(this.data.version!==1)throw Error('Unsupported gaze state version.');for(const job of Object.values(this.data.jobs))if(['matching','downloading'].includes(job.status))job.status='queued';this.save();}
 save(){atomicJson(this.file,this.data);}
 owner(id){return this.data.owners[id];}
 add(owner,track){if(!track.title?.trim()||!track.artists?.length)throw Error('A song title and artist are required.');const id=jobId(owner,track);const existing=this.data.jobs[id];if(existing)return existing;const job={...track,id,owner,status:'queued',createdAt:Date.now(),updatedAt:Date.now(),error:null};this.data.jobs[id]=job;this.save();return job;}
 publicState(owner,spotify,available){
  const jobs=Object.values(this.data.jobs).filter(j=>j.owner===owner),pending=jobs.filter(j=>!['ready','ignored'].includes(j.status));
  return {spotify,synopti:{available,enabled:this.data.botOwner===owner&&this.owner(owner)?.botEnabled===true,lastEventAt:this.owner(owner)?.lastEventAt||null,error:this.owner(owner)?.botError||null},sources:Object.values(this.data.sources).filter(s=>s.owner===owner),jobs:pending.map(({owner:_,...job})=>job),jobCounts:{saved:jobs.filter(j=>j.status==='ready').length,active:pending.length,needsAttention:pending.filter(j=>['needsMatch','failed'].includes(j.status)).length},qualityPolicy:'Best downloadable source audio, with lower-quality fallback when needed. No audio re-encoding.'};
 }

}
export function youtubeUrl(value){let u;try{u=new URL(String(value));}catch{throw Error('Paste a direct YouTube video link.');}if(u.protocol!=='https:'||u.username||u.password||u.port)throw Error('Paste a direct HTTPS YouTube video link.');let id;if(['www.youtube.com','youtube.com','music.youtube.com'].includes(u.hostname)&&u.pathname==='/watch')id=u.searchParams.get('v');else if(u.hostname==='youtu.be')id=u.pathname.slice(1);else if(['www.youtube.com','youtube.com'].includes(u.hostname)&&/^\/(shorts|embed)\//.test(u.pathname))id=u.pathname.split('/')[2];if(!/^[A-Za-z0-9_-]{11}$/.test(id||''))throw Error('Paste a link to one YouTube video, not a playlist.');return 'https://www.youtube.com/watch?v='+id;}
