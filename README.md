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

Run the container, minimal options
```
docker run -d \
    --name transmission \
    --user 1002:1002 \
    --cap-drop=ALL \
    -p 8080:8080 \
    -p 17000:17000 \
    -v $(pwd)/config:/config \
    -v $(pwd)/downloads:/downloads \
    docker-transmission-alpine
```
