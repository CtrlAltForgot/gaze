import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {youtubeUrl,normalized} from './store.js';
const execute=promisify(execFile);
// Keep Synopti's version/artist/explicit checks. When flat search omits artist
// attribution, inspect the full video metadata before accepting a recording.
export function creditedAlbumArtist(track,details){
 if(details.artist||details.artists?.length||!track.album||!track.spotifyArtists?.length)return null;
 const artist=normalized(track.spotifyArtists[0]).replace(/ /g,''),album=normalized(track.album);
 for(const link of (String(details.description||'').match(/https:\/\/[^\s<>()]+/g)||[])){
  try{const url=new URL(link.replace(/[.,]+$/,''));if(url.hostname===artist+'.bandcamp.com'&&url.pathname.startsWith('/album/')&&normalized(decodeURIComponent(url.pathname.split('/')[2]||''))===album)return track.spotifyArtists; }catch{}
 }
 return null;
}
export function createSynoptiResolver({playable,scoreSpotifyCandidate,ytArgs,run=execute}){
 return async function resolve(track,options={}){
  try{return await playable(track,options);}catch{}
  const query=track.spotifyTitle+' '+(track.spotifyArtists||[]).join(' ');
  let search;
  try{search=JSON.parse((await run('yt-dlp',[...ytArgs,'--dump-single-json','--skip-download','--flat-playlist','--playlist-end','10','ytsearch10:'+query],{timeout:60000,maxBuffer:4*1024*1024})).stdout);}catch{throw Error('YouTube search is unavailable. Retry later or paste an exact video link.');}
  const expected=Number(track.duration)||0;
  const candidates=(search.entries||[]).filter(c=>/^[A-Za-z0-9_-]{11}$/.test(c.id||'')&&!c.is_live&&normalized(c.title).includes(normalized(track.spotifyTitle))&&(!expected||!Number(c.duration)||Math.abs(Number(c.duration)-expected)<=Math.max(15,expected*.1))).slice(0,5);
  for(const candidate of candidates){
   try{
    const url=youtubeUrl('https://www.youtube.com/watch?v='+candidate.id);
    const details=JSON.parse((await run('yt-dlp',[...ytArgs,'--dump-single-json','--skip-download','--no-playlist',url],{timeout:60000,maxBuffer:4*1024*1024})).stdout);
    if(details.is_live||details.id!==candidate.id)continue;
    const credits=creditedAlbumArtist(track,details);const identified=credits?{...details,artist:credits.join(', '),artists:credits}:details;const score=scoreSpotifyCandidate(track,identified);if(!score)continue;
    const checked=await playable({...track,url,title:track.spotifyTitle,artist:track.spotifyArtists.join(', ')},options);
    return {...checked,matchedTitle:details.title,match:{score:score.score,channel:details.channel||details.uploader||details.artist||null,fullMetadataVerified:true,artistAlbumCredit:!!credits}};
   }catch{}
  }
  throw Error('No verified YouTube recording matched the song, artist, and version. Paste the exact video link.');
 };
}
