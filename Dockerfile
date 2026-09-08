# Hytale dedicated server, specialised for local hosting behind a dynamic IP.
#
# - Java 25 runtime (the Hytale server targets Java 25, QUIC transport)
# - Server files are downloaded at container start by the official
#   hytale-downloader CLI (keeps the image small and always up to date)
# - A stable machine-id is persisted inside the data volume so the encrypted
#   server auth (auth.enc) survives container restarts and rebuilds
# - An optional DDNS sidecar (see docker-compose.yml) keeps a hostname pointed
#   at your changing home IP, so players always connect to the same address

FROM eclipse-temurin:25-jre

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gosu \
        jq \
        tini \
        unzip \
    && rm -rf /var/lib/apt/lists/*

ENV HYTALE_HOME=/opt/hytale \
    HYTALE_DATA=/data

COPY scripts/ ${HYTALE_HOME}/scripts/

RUN chmod +x ${HYTALE_HOME}/scripts/*.sh \
    && mkdir -p ${HYTALE_DATA} \
    && groupadd -r -g 1000 hytale \
    && useradd -r -u 1000 -g hytale -d ${HYTALE_DATA} -s /bin/bash hytale \
    && chown -R hytale:hytale ${HYTALE_DATA}

# Hytale uses QUIC over UDP on port 5520 (NOT TCP).
EXPOSE 5520/udp

VOLUME ["/data"]

# tini reaps zombies and forwards signals; start-server.sh handles SIGTERM.
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/hytale/scripts/entrypoint.sh"]
