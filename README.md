# Simplest Torrent on Alpine I could muster

Build
```
docker build -t docker-transmission-alpine .
```

Make the paths needed and permissions, assuming 1002 uid:gid but it could be any
```
mkdir -p /home/transmission/config /home/transmission/downloads
chown -R 1002:1002 /home/transmission
chattr -R +C /home/transmission
```

Run the container, with minimal options even config volume is optional.
```
docker run -d \
    --name transmission \
    --user 1002:1002 \
    --cap-drop=ALL \
    --security-opts no-new-privileges \
    -p 8080:8080 \
    -p 17000:17000 \
    -v /home/transmission/downloads:/downloads \
    docker-transmission-alpine
```

If you want to adjust the scripts then map the config, run once, then edit the settings and add new script files accordingly. The script folder in this repo has the current defaults. 
```
    -v /home/transmission/config:/config \
```

Additional optional options
```
    -e WEBUI=8080 \ # web rpc port
    -e INCOMING=17000 \ # peer port
    -e UPNP=false \ # enable disable override for upnp
    -e WEBUSER="admin" \ # default web user
    -e WEBPASS="" \ # default password or not required if blank
    -e RSSFEEDS="" \ # feed reader and labeling. ie Linux:https://...,FreeBSD:https://...
    -e SCHEDULE="*/30 *" \ # lose cron'esq shedule pattern for start and/or recurrence but not comma delimited support
```
