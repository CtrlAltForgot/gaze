import {trackKey} from './store.js';
export class Jellyfin{
 constructor(origin,{fetchImpl=fetch,musicPath='/data/music/gaze Imports'}={}){this.origin=new URL(origin);if(!['http:','https:'].includes(this.origin.protocol)||this.origin.username||this.origin.password)throw Error('Invalid Jellyfin origin.');this.fetch=fetchImpl;this.musicPath=musicPath;this.cache=new Map();this.lastMusicRefresh=0;}
 async request(token,route,{method='GET',query={},body}={}){const u=new URL(this.origin);u.pathname=u.pathname.replace(/\/$/,'')+route;u.search=new URLSearchParams(query).toString();let response;try{response=await this.fetch(u,{method,headers:{'X-Emby-Token':token,...(body?{'content-type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(20000),redirect:'error'});}catch{throw Error('Jellyfin is unavailable. Imports will wait for the server.');}if(!response.ok){const e=Error(response.status===401||response.status===403?'Sign in to Jellyfin again to resume imports.':'Jellyfin could not save this change.');e.status=response.status;throw e;}return response.status===204?null:await response.text().then(x=>x?JSON.parse(x):null);}
 async authenticate(token){if(!token||token.length>4096)throw Error('Sign in to Jellyfin first.');const user=await this.request(token,'/Users/Me');if(!/^[a-f0-9]{32}$/i.test(user?.Id))throw Error('Jellyfin returned an invalid user.');return {id:user.Id,name:user.Name,admin:user.Policy?.IsAdministrator===true,token};}
 async songs(owner,force=false){const cached=this.cache.get(owner.id);if(!force&&cached&&cached.at>Date.now()-60000)return cached.items;const items=[];let offset=0,total;
 do{const page=await this.request(owner.token,`/Users/${owner.id}/Items`,{query:{IncludeItemTypes:'Audio',Recursive:'true',Fields:'Path,Artists,MediaStreams,Album,AlbumId,AlbumArtists,AlbumPrimaryImageTag,ArtistItems,ProviderIds',SortBy:'SortName',SortOrder:'Ascending',Limit:'500',StartIndex:String(offset)}});if(!Array.isArray(page?.Items)||!Number.isInteger(page.TotalRecordCount)||page.TotalRecordCount>100000||offset<page.TotalRecordCount&&!page.Items.length)throw Error('Jellyfin returned an incomplete music library.');items.push(...page.Items);offset+=page.Items.length;total=page.TotalRecordCount;}while(offset<total);this.cache.set(owner.id,{at:Date.now(),items});return items;}
 async find(owner,track,{relative}={}){const songs=await this.songs(owner,!!relative);return songs.find(s=>relative?s.Path===this.musicPath+'/'+relative.split('\\').join('/'):trackKey({title:s.Name,artists:s.Artists||[]})===trackKey(track))||null;}
 async item(owner,id){if(!/^[a-f0-9]{32}$/i.test(id))throw Error('Invalid music item.');return this.request(owner.token,`/Users/${owner.id}/Items/${id}`);}
 async artists(owner){const items=[];let offset=0,total;do{const page=await this.request(owner.token,'/Artists',{query:{UserId:owner.id,Recursive:'true',SortBy:'SortName',SortOrder:'Ascending',Limit:'500',StartIndex:String(offset),Fields:'ProviderIds'}});if(!Array.isArray(page?.Items)||!Number.isInteger(page.TotalRecordCount)||offset<page.TotalRecordCount&&!page.Items.length)throw Error('Jellyfin returned an incomplete artist library.');items.push(...page.Items);offset+=page.Items.length;total=page.TotalRecordCount;}while(offset<total);return items;}
 async libraryImage(owner,id){if(!/^[a-f0-9]{32}$/i.test(id||''))return null;const u=new URL(this.origin);u.pathname=u.pathname.replace(/\/$/,'')+`/Items/${id}/Images/Primary`;u.search=new URLSearchParams({maxWidth:'600',quality:'90'});const response=await this.fetch(u,{headers:{'X-Emby-Token':owner.token},signal:AbortSignal.timeout(20000),redirect:'error'});if(!response.ok)return null;const chunks=[];let size=0;for await(const chunk of response.body){size+=chunk.length;if(size>12*1024*1024)throw Error('Artist image too large.');chunks.push(chunk);}return {bytes:Buffer.concat(chunks)};}
 async saveMissingArtistImage(owner,id,image){return this.saveMissingCover(owner,id,image,'MusicArtist');}
 async saveMissingCover(owner,id,image,expectedType='MusicAlbum'){
  // Recheck just before uploading: a provider, another device, or the user may
  // have supplied a cover while the external search was running.
  const current=await this.item(owner,id);if(current.Type!==expectedType)throw Error('This item is no longer a music album.');if(current.ImageTags?.Primary)return false;
  const u=new URL(this.origin);u.pathname=u.pathname.replace(/\/$/,'')+`/Items/${id}/Images/Primary`;u.search='';
  const response=await this.fetch(u,{method:'POST',headers:{'X-Emby-Token':owner.token,'content-type':image.type},body:image.bytes.toString('base64'),signal:AbortSignal.timeout(20000),redirect:'error'});
  if(!response.ok)throw Error(response.status===403?'Your Jellyfin account cannot save library covers.':'Jellyfin could not save this cover. Try the artwork search again.');
  if(expectedType==='MusicAlbum')this.cache.delete(owner.id);const verified=await this.item(owner,id);if(!verified.ImageTags?.Primary)throw Error('Jellyfin has not confirmed the saved cover yet.');return true;
 }
 async scan(owner,relative){
  await this.request(owner.token,'/Library/Media/Updated',{method:'POST',body:{Updates:[{Path:this.musicPath,UpdateType:'Created'},{Path:this.musicPath+'/'+relative,UpdateType:'Created'}]}});
  // Newly created nested folders may not yet exist in Jellyfin's item tree.
  // Refresh only the music library containing our configured import folder.
  if(Date.now()-this.lastMusicRefresh>120000){
   const folders=await this.request(owner.token,'/Library/VirtualFolders');
   const music=folders.filter(f=>f.CollectionType==='music'&&f.Locations?.some(location=>this.musicPath.startsWith(location.replace(/\/$/,'')+'/')));
   if(music.length!==1)throw Error('The import folder is not inside one configured music library.');
   await this.request(owner.token,`/Items/${music[0].ItemId}/Refresh`,{method:'POST',query:{Recursive:'true',MetadataRefreshMode:'Default',ImageRefreshMode:'Default',ReplaceAllMetadata:'false',ReplaceAllImages:'false'}});
   this.lastMusicRefresh=Date.now();
  }
  this.cache.delete(owner.id);
 }
 async entries(owner,id){const items=[];let offset=0,total;do{const p=await this.request(owner.token,`/Playlists/${id}/Items`,{query:{UserId:owner.id,StartIndex:String(offset),Limit:'500'}});if(!Array.isArray(p?.Items)||!Number.isInteger(p.TotalRecordCount)||offset<p.TotalRecordCount&&!p.Items.length)throw Error('Jellyfin returned an incomplete playlist.');items.push(...p.Items);offset+=p.Items.length;total=p.TotalRecordCount;}while(offset<total);return items;}
 async mirror(owner,source,desired,checkpoint=()=>{}){
  desired=[...new Set(desired)];
  if(!source.jellyfinId){const created=await this.request(owner.token,'/Playlists',{method:'POST',body:{Name:source.name,UserId:owner.id,MediaType:'Audio',Ids:desired,IsPublic:false,Users:[]}});if(!/^[a-f0-9]{32}$/i.test(created?.Id))throw Error('Jellyfin did not return a saved playlist.');source.jellyfinId=created.Id;checkpoint();}
  const permissions=await this.request(owner.token,`/Playlists/${source.jellyfinId}/Users/${owner.id}`);if(permissions?.CanEdit!==true)throw Error('This linked playlist is no longer editable by your account.');
  // The only IDs touched here are service-created playlists, never arbitrary user IDs.
  const metadata=await this.request(owner.token,`/Users/${owner.id}/Items/${source.jellyfinId}`);if(metadata.Type!=='Playlist')throw Error('The linked object is no longer a playlist.');if(metadata.Name!==source.name){await this.request(owner.token,`/Playlists/${source.jellyfinId}`,{method:'POST',body:{Name:source.name}});}
  let entries=await this.entries(owner,source.jellyfinId);const add=desired.filter(id=>!entries.some(e=>e.Id===id));
  if(add.length){await this.request(owner.token,`/Playlists/${source.jellyfinId}/Items`,{method:'POST',query:{UserId:owner.id,Ids:add.join(',')}});entries=await this.entries(owner,source.jellyfinId);}
  const remove=entries.filter((e,i)=>!desired.includes(e.Id)||entries.findIndex(x=>x.Id===e.Id)!==i).map(e=>e.PlaylistItemId);if(remove.some(x=>!x))throw Error('Jellyfin returned invalid playlist entries.');
  if(remove.length){await this.request(owner.token,`/Playlists/${source.jellyfinId}/Items`,{method:'DELETE',query:{EntryIds:remove.join(',')}});entries=await this.entries(owner,source.jellyfinId);}
  for(let i=0;i<desired.length;i++){const from=entries.findIndex(e=>e.Id===desired[i]);if(from<0)throw Error('Jellyfin did not keep an imported song.');if(from!==i){const [entry]=entries.splice(from,1);if(!entry.PlaylistItemId)throw Error('Jellyfin returned an invalid playlist entry.');await this.request(owner.token,`/Playlists/${source.jellyfinId}/Items/${entry.PlaylistItemId}/Move/${i}`,{method:'POST'});entries.splice(i,0,entry);}}
  const verified=await this.entries(owner,source.jellyfinId);if(JSON.stringify(verified.map(e=>e.Id))!==JSON.stringify(desired))throw Error('Jellyfin did not save the full playlist order.');
 }
}
