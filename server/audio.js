import fs from 'node:fs';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {youtubeUrl} from './store.js';
import {applySynoptiCredits} from './synopti-source.js';
const execute=promisify(execFile);
export const QUALITY_ARGS=['--ignore-config','--no-warnings','--no-cache-dir','--no-playlist','--socket-timeout','20','--retries','3','--js-runtimes','node','-f','bestaudio/best','-S','quality,acodec,abr,asr','--max-filesize','2G'];
const localArgs=['-nostdin','-v','error','-protocol_whitelist','file,pipe'];
function segment(value){return String(value||'Unknown').normalize('NFKC').replace(/[\x00-\x1f<>:"/\\|?*]/g,'_').replace(/^\.+|\.+$/g,'').trim().slice(0,100)||'Unknown';}
export async function probe(file,run=execute,{allowVideo=false}={}){const {stdout}=await run('ffprobe',['-v','error','-protocol_whitelist','file,pipe','-show_streams','-show_format','-of','json',file],{timeout:30000,maxBuffer:1024*1024});const data=JSON.parse(stdout),stream=data.streams?.find(s=>s.codec_type==='audio');if(!stream||(!allowVideo&&data.streams.some(s=>s.codec_type==='video'))||!Number(data.format?.duration))throw Error('The source did not contain a valid audio-only stream.');return {codec:stream.codec_name,sampleRate:Number(stream.sample_rate)||null,channels:stream.channels||null,bitrate:Number(stream.bit_rate||data.format?.bit_rate)||null,duration:Number(data.format.duration)};}
export async function packetHash(file,run=execute){const {stdout}=await run('ffmpeg',[...localArgs,'-i',file,'-map','0:a:0','-c:a','copy','-f','hash','-hash','sha256','-'],{timeout:120000,maxBuffer:2048});const hash=stdout.trim();if(!/^SHA256=[a-f0-9]{64}$/i.test(hash))throw Error('Audio integrity could not be verified.');return hash;}
export async function publishAudio(input,job,musicRoot,{run=execute}={}){
 const before=await probe(input,run,{allowVideo:true});const extensions={opus:'opus',vorbis:'ogg',aac:'m4a',mp3:'mp3',flac:'flac',alac:'m4a',pcm_s16le:'wav',pcm_s24le:'wav'};const ext=extensions[before.codec];if(!ext)throw Error('This source codec cannot be saved without re-encoding.');
 const relative=path.join(segment(job.artists[0]),segment(job.album||job.title),segment(job.title)+' -- '+job.id+'.'+ext),target=path.join(musicRoot,relative);fs.mkdirSync(path.dirname(target),{recursive:true});const staging=target+'.staging.'+ext;
 try{
  if(fs.existsSync(target)){const saved=await probe(target,run);if(await packetHash(input,run)!==await packetHash(target,run))throw Error('A different saved file already exists. It was kept.');return {relative,quality:{...saved,sourceFormatId:job.sourceFormatId||null,originalAudio:true,audioSha256:await packetHash(target,run)}};}
  await run('ffmpeg',[...localArgs,'-y','-i',input,'-map','0:a:0','-c:a','copy','-metadata','title='+job.title,'-metadata','artist='+job.artists.join('; '),'-metadata','album_artist='+(job.albumArtists||job.artists).join('; '),'-metadata','album='+(job.album||job.title),...(job.isrc?['-metadata','ISRC='+job.isrc]:[]),...(job.year?['-metadata','date='+job.year]:[]),staging],{timeout:120000,maxBuffer:1024*1024});
  const after=await probe(staging,run),original=await packetHash(input,run),saved=await packetHash(staging,run);
  if(before.codec!==after.codec||before.sampleRate!==after.sampleRate||before.channels!==after.channels||original!==saved)throw Error('Audio changed during tagging. The import was stopped.');
  // link is atomic and refuses to overwrite a concurrent file.
  fs.linkSync(staging,target);return {relative,quality:{...after,sourceFormatId:job.sourceFormatId||null,originalAudio:true,audioSha256:saved}};
 }finally{fs.rmSync(staging,{force:true});}
}
// yt-dlp returns formats sorted from worst to best under QUALITY_ARGS' sort.
// Prefer audio-only sources, then copy audio out of combined sources if needed.
function audioFormats(info){
 const formats=(info.formats||[]).slice().reverse().filter(f=>f.acodec!=='none'&&(f.acodec||f.vcodec==='none')&&!f.has_drm&&/^[A-Za-z0-9_.-]+$/.test(String(f.format_id||'')));
 return [...new Set([...formats.filter(f=>f.vcodec==='none'),...formats.filter(f=>f.vcodec!=='none')].map(f=>String(f.format_id)))];
}
export async function downloadAudio(job,{directory,musicRoot,run=execute}){
 const url=youtubeUrl(job.youtubeUrl),folder=path.join(directory,'staging',job.id);
 const unavailable=()=>Error('No available audio format could be downloaded. Retry or choose another YouTube link.');
 try{
  let info;
  try{const {stdout}=await run('yt-dlp',[...QUALITY_ARGS,'--dump-single-json','--skip-download','--ignore-no-formats-error',url],{timeout:120000,maxBuffer:8*1024*1024});info=JSON.parse(stdout);}catch{throw unavailable();}
  if(info.is_live)throw Error('Live recordings need a manual source choice.');
  applySynoptiCredits(job,info);
  const formats=audioFormats(info);
  for(let index=0;index<formats.length;index++){
   // A failed format must never leave partial bytes or metadata for the next.
   fs.rmSync(folder,{recursive:true,force:true});fs.mkdirSync(folder,{recursive:true});
   const args=[...QUALITY_ARGS];args[args.indexOf('-f')+1]=formats[index];
   let input,downloadedInfo;
   try{
    const {stdout}=await run('yt-dlp',[...args,'--write-info-json','--print','after_move:filepath','-o',path.join(folder,'source.%(ext)s'),url],{timeout:1200000,maxBuffer:2*1024*1024});
    input=stdout.trim().split('\n').at(-1);
    if(!input||path.dirname(path.resolve(input))!==path.resolve(folder)||!fs.existsSync(input))continue;
    downloadedInfo=JSON.parse(fs.readFileSync(path.join(folder,'source.info.json'),'utf8'));
   }catch{continue;}
   if(downloadedInfo.is_live)throw Error('Live recordings need a manual source choice.');
   job.sourceFormatId=String(downloadedInfo.format_id||formats[index]);
   // Publication/integrity failures are not download failures; never hide them.
   const saved=await publishAudio(input,job,musicRoot,{run});
   saved.quality.fallbackUsed=index>0;
   return saved;
  }
  throw unavailable();
 }finally{fs.rmSync(folder,{recursive:true,force:true});}
}
