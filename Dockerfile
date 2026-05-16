FROM alpine:edge

ARG APP_VERSION=0.0.3
ARG NIGHTLY_URL="https://github.com/transmission/transmission-nightly/releases/latest/download/transmission-nightly-x86_64.tar.xz"

ENV WEBUI=8080 \
  INCOMING=17000 \
  UPNP=false \
  WEBUSER=admin \
  WEBPASS="" \
  RSSFEEDS="" \
  SCHEDULE="*/30 *"

RUN apk add --no-cache \
    tini ca-certificates curl grep sed jq tar xz \
    libevent libcurl libssl3

# Download and install Transmission nightly
RUN mkdir -p /opt/transmission && \
    curl -L "$NIGHTLY_URL" -o /tmp/transmission.tar.xz && \
    tar -xf /tmp/transmission.tar.xz -C /opt/transmission --strip-components=1 && \
    ln -s /opt/transmission/bin/transmission-daemon /usr/bin/transmission-daemon && \
    ln -s /opt/transmission/bin/transmission-remote /usr/bin/transmission-remote && \
    rm /tmp/transmission.tar.xz

RUN mkdir -p /config /opt/default-scripts

ADD https://raw.githubusercontent.com/HuwSy/docker-transmission-alpine/refs/heads/main/scripts/on-complete.sh /opt/default-scripts/on-complete.sh
ADD https://raw.githubusercontent.com/HuwSy/docker-transmission-alpine/refs/heads/main/scripts/on-added.sh /opt/default-scripts/on-added.sh
ADD https://raw.githubusercontent.com/HuwSy/docker-transmission-alpine/refs/heads/main/scripts/rss-fetch.sh /opt/default-scripts/rss-fetch.sh
ADD https://raw.githubusercontent.com/HuwSy/docker-transmission-alpine/refs/heads/main/scripts/start-transmission.sh /opt/start-transmission.sh

RUN chmod -R 755 /opt/default-scripts && \
    chmod 755 /opt/start-transmission.sh && \
    chmod -R 0777 /config

EXPOSE 8080 17000/tcp 17000/udp

VOLUME /config

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/start-transmission.sh"]
