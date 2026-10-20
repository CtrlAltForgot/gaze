import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync, execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {Store} from '../store.js';
import {Worker} from '../worker.js';
import {downloadAudio, packetHash, probe} from '../audio.js';
const execute = promisify(execFile);
const folder = () => fs.mkdtempSync(path.join(os.tmpdir(), 'gaze-recovery-'));
const track = {title:'Song', artists:['Artist'], duration:1};
const downloadJob = {...track, id:'a'.repeat(32), youtubeUrl:'https://youtu.be/dQw4w9WgXcQ'};

test('queue hides resolved entries while retaining history, mirrors, and account scope', async () => {
 const dir=folder();try {
  const store=new Store(dir);
  const jobs=['Saved','Excluded','Retry','Match','Pending'].map(title=>store.add('a',{...track,title}));
  const [ready,ignored,failed,matching,queued]=jobs;
  ready.status='ready';ready.itemId='saved';ignored.status='ignored';failed.status='failed';matching.status='needsMatch';
  store.add('b',{...track,title:'Private'});
  const source={owner:'a',enabled:true,snapshot:'v1',dirty:true,jobIds:[ready.id,failed.id],unavailable:0};
  store.data.sources.p=source;store.save();
  let state=store.publicState('a',{},false);
  assert.deepEqual(state.jobs.map(j=>j.id),[failed.id,matching.id,queued.id]);
  assert.deepEqual(state.jobCounts,{saved:1,active:3,needsAttention:2});
  assert(state.jobs.every(j=>!('owner' in j)));
  failed.status='ready';failed.itemId='retried';store.save();state=store.publicState('a',{},false);
  assert(!state.jobs.some(j=>j.id===failed.id));assert.equal(state.jobCounts.saved,2);
  assert.equal(new Store(dir).add('a',{...track,title:'Saved'}).id,ready.id);
  let mirrored;store.data.owners.a={token:'t'};
  const worker=new Worker({store,jellyfin:{mirror:async(_owner,_source,ids)=>{mirrored=ids;}}});
  await worker.mirror(source);assert.deepEqual(mirrored,['saved','retried']);
 }finally{fs.rmSync(dir,{recursive:true});}
});

function fixture(dir,{fail=[],combined=false,publishFailure=false}={}){
 const original=path.join(dir,combined?'original.mp4':'original.webm');
 execFileSync('ffmpeg',['-v','error',...(combined?['-f','lavfi','-i','color=size=16x16:duration=1']:[]),'-f','lavfi','-i','sine=frequency=440:duration=1',...(combined?['-c:v','mpeg4','-c:a','aac']:['-c:a','libopus']),original]);
 const attempts=[];
 const formats=combined?[{format_id:'18',acodec:'aac',vcodec:'h264'}]:[{format_id:'250',acodec:'opus',vcodec:'none'},{format_id:'251',acodec:'opus',vcodec:'none'}];
 const run=async(cmd,args,options)=>{
  if(cmd!=='yt-dlp'){
   if(publishFailure&&cmd==='ffmpeg')throw Error('Audio integrity could not be verified.');
   return execute(cmd,args,options);
  }
  if(args.includes('--dump-single-json'))return {stdout:JSON.stringify({formats})};
  const format=args[args.indexOf('-f')+1];attempts.push(format);
  const source=args[args.indexOf('-o')+1].replace('%(ext)s',combined?'mp4':'webm');
  if(fail.includes(format)){fs.writeFileSync(source+'.part','partial');throw Error('Download failed with private signed URL');}
  assert(!fs.existsSync(source+'.part'));fs.copyFileSync(original,source);
  fs.writeFileSync(path.join(path.dirname(source),'source.info.json'),JSON.stringify({format_id:format}));return {stdout:source+'\n'};
 };
 return {run,attempts,original};
}

test('failed highest audio retries lower quality and preserves actual audio packets',async()=>{
 const dir=folder();try{
  const f=fixture(dir,{fail:['251']}),job={...downloadJob};
  const saved=await downloadAudio(job,{directory:dir,musicRoot:path.join(dir,'music'),run:f.run});
  assert.deepEqual(f.attempts,['251','250']);assert.equal(saved.quality.sourceFormatId,'250');assert.equal(saved.quality.fallbackUsed,true);
  assert.equal(await packetHash(f.original),await packetHash(path.join(dir,'music',saved.relative)));
  assert(!fs.existsSync(path.join(dir,'staging',job.id)));
 }finally{fs.rmSync(dir,{recursive:true});}
});
test('successful highest audio does not download lower formats',async()=>{
 const dir=folder();try{
  const f=fixture(dir),saved=await downloadAudio({...downloadJob},{directory:dir,musicRoot:path.join(dir,'music'),run:f.run});
  assert.deepEqual(f.attempts,['251']);assert.equal(saved.quality.fallbackUsed,false);
 }finally{fs.rmSync(dir,{recursive:true});}
});
test('combined source extracts only original audio with identical packets',async()=>{
 const dir=folder();try{
  const f=fixture(dir,{combined:true}),saved=await downloadAudio({...downloadJob},{directory:dir,musicRoot:path.join(dir,'music'),run:f.run});
  assert.deepEqual(f.attempts,['18']);assert.equal(saved.quality.codec,'aac');
  const target=path.join(dir,'music',saved.relative);await probe(target);
  assert.equal(await packetHash(f.original),await packetHash(target));
 }finally{fs.rmSync(dir,{recursive:true});}
});
test('exhausted formats leave a clear error and no partial or published files',async()=>{
 const dir=folder();try{
  const f=fixture(dir,{fail:['251','250']});
  await assert.rejects(downloadAudio({...downloadJob},{directory:dir,musicRoot:path.join(dir,'music'),run:f.run}),/^Error: No available audio format could be downloaded/);
  assert.deepEqual(f.attempts,['251','250']);assert(!fs.existsSync(path.join(dir,'staging',downloadJob.id)));assert(!fs.existsSync(path.join(dir,'music')));
 }finally{fs.rmSync(dir,{recursive:true});}
});
test('publication failures remain visible and never trigger another format',async()=>{
 const dir=folder();try{
  const f=fixture(dir,{publishFailure:true});
  await assert.rejects(downloadAudio({...downloadJob},{directory:dir,musicRoot:path.join(dir,'music'),run:f.run}),/Audio integrity/);
  assert.deepEqual(f.attempts,['251']);
 }finally{fs.rmSync(dir,{recursive:true});}
});

test('indexing clears saved work before older queued imports without starving downloads',async()=>{
 const dir=folder();try{
  const store=new Store(dir);store.data.owners.a={token:'t'};
  const queued=store.add('a',{...track,title:'Old queued'}),scanning=store.add('a',{...track,title:'Saved file'});
  queued.updatedAt=1;scanning.updatedAt=2;scanning.status='scanning';scanning.relative='saved.opus';
  const processed=[];
  const worker=new Worker({store,jellyfin:{find:async(_owner,job)=>{processed.push(job.id);return {Id:job.id};}},download:()=>assert.fail('Saved audio must not download again')});
  await worker.tick();assert.deepEqual(processed,[scanning.id,queued.id]);assert.equal(scanning.status,'ready');assert.equal(queued.status,'ready');
 }finally{fs.rmSync(dir,{recursive:true});}
});
test('audio-only HLS with unspecified codec still downloads and is validated',async()=>{
 const dir=folder();try{
  const f=fixture(dir),run=async(cmd,args,options)=>cmd==='yt-dlp'&&args.includes('--dump-single-json')?{stdout:JSON.stringify({formats:[{format_id:'233',acodec:null,vcodec:'none'}]})}:f.run(cmd,args,options);
  const saved=await downloadAudio({...downloadJob},{directory:dir,musicRoot:path.join(dir,'music'),run});assert.deepEqual(f.attempts,['233']);assert.equal(saved.quality.originalAudio,true);
 }finally{fs.rmSync(dir,{recursive:true});}
});

test('one complete library snapshot clears every indexed save before another download',async()=>{
 const dir=folder();try{
  const store=new Store(dir);store.data.owners.a={token:'t'};store.data.owners.b={token:'u'};
  const jobs=['One','Two','Still indexing'].map(title=>store.add('a',{...track,title}));
  for(const [index,job] of jobs.entries()){job.status='scanning';job.relative=index+'.opus';}
  const other=store.add('b',{...track,title:'Private'});other.status='scanning';other.relative='0.opus';
  const source={owner:'a',jobIds:jobs.map(j=>j.id),dirty:false};store.data.sources.p=source;
  let snapshots=0;
  const worker=new Worker({store,jellyfin:{musicPath:'/music',songs:async owner=>{snapshots++;assert.equal(owner.id,'a');return [{Id:'one',Path:'/music/0.opus'},{Id:'two',Path:'/music/1.opus'}];}}});
  await worker.reconcileSaved(jobs);assert.equal(snapshots,1);assert.deepEqual(jobs.map(j=>j.status),['ready','ready','scanning']);assert.equal(source.dirty,true);assert.equal(other.status,'scanning');assert.equal(store.publicState('a',{},false).jobs.length,1);assert.equal(new Store(dir).data.jobs[jobs[0].id].itemId,'one');
 }finally{fs.rmSync(dir,{recursive:true});}
});
test('incomplete indexing snapshots retain pending work and never claim readiness',async()=>{
 const dir=folder();try{
  const store=new Store(dir);store.data.owners.a={token:'t'};const job=store.add('a',track);job.status='scanning';job.relative='saved.opus';
  const worker=new Worker({store,jellyfin:{songs:async()=>{throw Error('Incomplete library');}}});await worker.reconcileSaved([job]);assert.equal(job.status,'scanning');assert.equal(job.itemId,undefined);
 }finally{fs.rmSync(dir,{recursive:true});}
});
