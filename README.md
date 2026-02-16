# Simplest Torrent on Alpine I could muster

## Build

```
docker build -t docker-transmission-alpine .
```

## Configuration

Create the required paths and set permissions, assuming 1002 uid:gid (or any other user):

```
mkdir -p /home/transmission/config /home/transmission/downloads
chown -R 1002:1002 /home/transmission
chattr -R +C /home/transmission
```

## Running the Container

Run the container with minimal options. This requires the downloads directory to be a mounted volume at runtime. The container will refuse to start if /downloads is not a mount. The config volume is optional.

```
docker run -d \
    --name transmission \
    --user 1002:1002 \
    --cap-drop=ALL \
    --security-opts no-new-privileges \
    --read-only \
    -p 8080:8080 \
    -p 17000:17000 \
    -v /home/transmission/downloads:/downloads \
    docker-transmission-alpine
```

## Configuration Volume (Optional)

If you want to adjust the scripts, map the config volume, run once, then edit the settings and add new script files accordingly. The script folder in this repo has the current defaults:

```
    -v /home/transmission/config:/config \
```

## Environment Variables (Optional)

- `WEBUI=8080` - Web RPC port
- `INCOMING=17000` - Peer port
- `UPNP=false` - Enable/disable override for UPnP
- `WEBUSER="admin"` - Default web user
- `WEBPASS=""` - Default password (not required if blank)
- `RSSFEEDS=""` - Feed reader and labeling (e.g., Linux:https://...,FreeBSD:https://...)
- `SCHEDULE="*/30 *"` - Cron-like schedule pattern for start and/or recurrence (no comma-delimited support)

Example with environment variables:

```
docker run -d \
    --name transmission \
    --user 1002:1002 \
    --cap-drop=ALL \
    --security-opts no-new-privileges \
    -p 8080:8080 \
    -p 17000:17000 \
    -v /home/transmission/downloads:/downloads \
    -v /home/transmission/config:/config \
    -e WEBUI=8080 \
    -e INCOMING=17000 \
    -e UPNP=false \
    -e WEBUSER="admin" \
    -e WEBPASS="" \
    -e RSSFEEDS="" \
    -e SCHEDULE="*/30 *" \
    docker-transmission-alpine
```
