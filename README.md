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

If you want to adjust the scripts then map the config, make new files and update settings accordingly.
