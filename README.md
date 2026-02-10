# Simplest Torrent on Alpine I could muster

Build
```
docker build -t docker-transmission-alpine .
```

Make the paths needed and permissions, assuming 1002 uid:gid but could be any
```
mkdir -p /home/transmission/config /home/transmission/downloads
chown -R 1002:1002 /home/transmission
chattr -R +C /home/transmission
```

Run the container
```
docker run -d \
    --name transmission \
    --user 1002:1002 \ # rootless
    --cap-drop=ALL \ # no Linux capabilities
    -p 9091:9091 \ # WebUI
    -p 51413:51413 \ # torrent port
    \
    -e RSS_URLS="URL1,URL2" \ # optional, comma-separated RSS feeds
    -e RSS_LABELS="Linux,FreeBSD" \ # optional, auto-label per feed
    -e RSS_SCHEDULE="*/30 * * * *" \ # optional, cron schedule for feeds
    \
    -e TRANSMISSION_PASSWORD="" \ # optional, empty = no auth
    -e TRANSMISSION_INCOMING_PORT=51413 \ # optional, should match port mapping
    -e TRANSMISSION_UPNP=false \ # optional, upnp enabled
    \
    -v $(pwd)/config:/config \ # settings.json lives here
    -v $(pwd)/downloads:/downloads \ # completed files sorted here
    -v $(pwd)/scripts:/scripts \ # user scripts override defaults
    \
    docker-transmission-alpine
```
