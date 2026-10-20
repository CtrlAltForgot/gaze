// Standalone public server for people who do not use the optional Synopti imports.
import http from 'node:http';
import {Jellyfin} from './jellyfin.js';
import {Parties} from './party.js';
import {partyRoute} from './party-http.js';
if (!process.env.JELLYFIN_URL) throw Error('Set JELLYFIN_URL.');
const jellyfin = new Jellyfin(process.env.JELLYFIN_URL);
const parties = new Parties({jellyfin,publicOrigin:process.env.GAZE_PUBLIC_ORIGIN,guests:process.env.GAZE_PARTY_GUESTS === 'true'});
const send = (res,status,data) => {res.writeHead(status,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(JSON.stringify(data));};
const readBody = async req => {let size=0;const chunks=[];for await (const chunk of req) {size+=chunk.length;if(size>131072)throw Error('Request too large.');chunks.push(chunk);}return JSON.parse(Buffer.concat(chunks).toString() || '{}');};
const server=http.createServer(async(req,res)=>{
 try {
  const url=new URL(req.url,'http://gaze');
  if (await partyRoute(req,res,url,{parties,jellyfin,readBody,send}))return;
  if (req.method==='GET' && url.pathname==='/health')return send(res,200,{ok:true,service:'gaze-party',version:1});
  if (req.method==='GET' && url.pathname==='/v1/state' && !req.headers.origin) {
    await jellyfin.authenticate(req.headers.authorization?.replace(/^Bearer /,''));
    return send(res,200,{partyOnly:true,spotify:{},synopti:{},sources:[],jobs:[]});
  }
  send(res,404,{error:'Action not found.'});
 } catch (e) { if(res.headersSent)return res.destroy();send(res,Number.isInteger(e.status)?e.status:400,{error:e.status?e.message:'The request could not be completed.'}); }
});
const timer=setInterval(()=>parties.prune(),5000);
server.listen(Number(process.env.GAZE_PORT || 8097),process.env.GAZE_BIND || '0.0.0.0');
process.on('SIGTERM',()=>{clearInterval(timer);for(const id of parties.sessions.keys())parties.end(id);server.close(()=>process.exit(0));});
