"""Read public YouTube Music song metadata; never fetch audio or user sessions."""
import json
import sys
import re
from urllib.parse import urlparse
from ytmusicapi import YTMusic


def candidates(query, client):
    result = []
    for song in client.search(query, filter='songs', limit=20, ignore_spelling=True)[:20]:
        album = song.get('album') or {}
        if song.get('resultType') != 'song' or not album.get('id'):
            continue
        images = [image for image in song.get('thumbnails', [])
                  if image.get('width', 0) > 0 and image.get('height', 0) > 0]
        if not images:
            continue
        image = max(images, key=lambda value: value.get('width', 0))
        image_url = image['url']
        if urlparse(image_url).hostname in ('yt3.googleusercontent.com', 'lh3.googleusercontent.com'):
            image_url = re.sub(r'=w[0-9]+-h[0-9]+', '=w600-h600', image_url)
        result.append({
            'title': song.get('title'),
            'artists': [artist['name'] for artist in song.get('artists', []) if artist.get('name')],
            'album': album.get('name'),
            'duration': song.get('duration_seconds'),
            'image': image_url,
            'source': 'YouTube Music',
            'sourceUrl': 'https://music.youtube.com/watch?v=' + song['videoId'],
        })
    return result


if __name__ == '__main__':
    try:
        print(json.dumps(candidates(sys.argv[1], YTMusic())))
    except Exception:
        # Provider responses may contain request details. Keep them out of logs.
        print('YouTube Music artwork search is temporarily unavailable.', file=sys.stderr)
        sys.exit(1)
