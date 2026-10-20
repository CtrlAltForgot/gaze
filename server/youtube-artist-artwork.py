"""Find catalog artist portraits corroborated by a song already in the library."""
import json,re,sys,unicodedata
from ytmusicapi import YTMusic

def key(value):
    value=unicodedata.normalize('NFKC',str(value or '')).lower().replace('$','s')
    return ''.join(c for c in value if c.isalnum())

def find_artist(identity,client):
    name=identity['name'];samples=identity.get('songs',[])[:3]
    if ';' in name or not samples:return []
    matches=[r for r in client.search(name.replace('$','s'),filter='artists',limit=8,ignore_spelling=True)
             if r.get('resultType')=='artist' and key(r.get('artist'))==key(name) and r.get('browseId','').startswith('UC')]
    for artist in matches[:3]:
        verified=False
        for sample in samples[:2]:
            songs=client.search(name+' '+sample,filter='songs',limit=5,ignore_spelling=True)
            if any(key(s.get('title'))==key(sample) and any(a.get('id')==artist['browseId'] for a in s.get('artists',[])) for s in songs):
                verified=True;break
        if not verified:continue
        images=[i for i in artist.get('thumbnails',[]) if i.get('width',0)>0]
        if not images:continue
        image=max(images,key=lambda i:i['width'])['url']
        image=re.sub(r'=w\d+-h\d+','=w600-h600',image)
        return [{'name':artist['artist'],'image':image,'source':'YouTube Music artist','sourceUrl':'https://music.youtube.com/channel/'+artist['browseId']}]
    return []

if __name__=='__main__':
    try:print(json.dumps(find_artist(json.loads(sys.argv[1]),YTMusic())))
    except Exception:
        print('Artist catalog temporarily unavailable.',file=sys.stderr);sys.exit(1)
