FROM alpine:edge

ENV WEBUI=8080 \
  INCOMING=17000 \
  UPNP=false \
  WEBUSER=admin \
  WEBPASS="" \
  RSSFEEDS="" \
  SCHEDULE="*/30 *"

RUN apk add --no-cache \
  transmission-daemon \
  transmission-cli \
  tini ca-certificates curl grep sed jq

RUN mkdir -p /config /downloads /opt/default-scripts

COPY scripts/on-complete.sh /opt/default-scripts/on-complete.sh
COPY scripts/on-added.sh /opt/default-scripts/on-added.sh
COPY scripts/rss-fetch.sh /opt/default-scripts/rss-fetch.sh
COPY scripts/start-transmission.sh /opt/start-transmission.sh

RUN chmod -R 755 /opt/default-scripts && \
    chmod 755 /opt/start-transmission.sh

USER 1002:1002

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/start-transmission.sh"]

EXPOSE 8080 17000/tcp 17000/udp
