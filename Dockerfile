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

# The temurin base image ships an "ubuntu" user/group with UID/GID 1000 —
# rename it to "hytale", otherwise create the user fresh.
RUN chmod +x ${HYTALE_HOME}/scripts/*.sh \
    && mkdir -p ${HYTALE_DATA} \
    && if getent passwd 1000 >/dev/null; then \
        existing="$(id -un 1000)"; \
        usermod -l hytale -d "${HYTALE_DATA}" -s /bin/bash "${existing}"; \
        if getent group "${existing}" >/dev/null; then groupmod -n hytale "${existing}"; fi; \
    else \
        getent group 1000 >/dev/null || groupadd -g 1000 hytale; \
        useradd -u 1000 -g 1000 -d "${HYTALE_DATA}" -s /bin/bash hytale; \
    fi \
    && chown -R 1000:1000 ${HYTALE_DATA}

# Hytale uses QUIC over UDP on port 5520 (NOT TCP).
EXPOSE 5520/udp

VOLUME ["/data"]

# tini reaps zombies and forwards signals; start-server.sh handles SIGTERM.
STOPSIGNAL SIGTERM

# -g: forward signals to the whole process group so the java server also
# receives SIGTERM, letting it save and shut down even if the trap is busy.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/hytale/scripts/entrypoint.sh"]
