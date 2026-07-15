# syntax=docker/dockerfile:1
#
# mongodb-slim: MongoDB Community Server on Chainguard Wolfi (glibc).
#
# MongoDB doesn't ship a musl/Alpine or apk build of the server, but it does ship
# glibc binary tarballs. Wolfi is a minimal, glibc-based, apk-driven distro, so
# MongoDB's official ubuntu2404 (OpenSSL 3) binaries just run on it. Nothing is
# compiled, there's no glibc shim, and every download is checksum-verified below.
#
# The version and checksum values are build args so CI can bump them without
# touching this file. See scripts/resolve-versions.py.

ARG BASE_IMAGE=cgr.dev/chainguard/wolfi-base:latest

# MongoDB server: the community "targeted" ubuntu2404 tarball, built against OpenSSL 3.
ARG MONGO_VERSION=8.0.26
ARG MONGO_TARGET=ubuntu2404
ARG MONGO_SHA256_AMD64=e5be0cc89d7439cd3fd49d78030c590c7d6f0d1bfe615ac54a30751b5d4c63f4
ARG MONGO_SHA256_ARM64=32390bc7e303da3965db90acee14f23e2cb7fa37aa9391910b07a522452fb0e3

# mongosh: the matching OpenSSL 3 build from the GitHub releases page.
ARG MONGOSH_VERSION=2.9.2
ARG MONGOSH_SHA256_AMD64=36e13df6feac978c819c5902fe8ba279b34fef42acbc65e09d01aff9ee62e40c
ARG MONGOSH_SHA256_ARM64=10c0ae51125b7942aec3c68ee00587f2f4e275b2b7393e4e1746d4c3c86728d4


##############################################################################
# Stage 1: download the official binaries and verify their checksums.
##############################################################################
FROM ${BASE_IMAGE} AS fetch

ARG MONGO_VERSION
ARG MONGO_TARGET
ARG MONGO_SHA256_AMD64
ARG MONGO_SHA256_ARM64
ARG MONGOSH_VERSION
ARG MONGOSH_SHA256_AMD64
ARG MONGOSH_SHA256_ARM64
# buildx sets this automatically for each platform: "amd64" or "arm64".
ARG TARGETARCH

USER root
# We only need a downloader. The base image's busybox tar already handles
# gzip and --strip-components, so there's no separate tar package to install.
RUN apk add --no-cache curl

WORKDIR /work
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) mongo_arch=x86_64;  mongo_sha="${MONGO_SHA256_AMD64}"; sh_arch=x64;   sh_sha="${MONGOSH_SHA256_AMD64}" ;; \
      arm64) mongo_arch=aarch64; mongo_sha="${MONGO_SHA256_ARM64}"; sh_arch=arm64; sh_sha="${MONGOSH_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /rootfs/usr/local/bin; \
    \
    mongo_url="https://fastdl.mongodb.org/linux/mongodb-linux-${mongo_arch}-${MONGO_TARGET}-${MONGO_VERSION}.tgz"; \
    echo "==> mongod:  ${mongo_url}"; \
    curl -fsSL -o mongo.tgz "${mongo_url}"; \
    echo "${mongo_sha}  mongo.tgz" | sha256sum -c -; \
    mkdir -p /work/server; \
    tar -xzf mongo.tgz -C /work/server; \
    # We ship mongod only. mongos is the sharded-cluster router, which nobody
    # runs from a single-container image, and leaving it out keeps this the
    # leanest MongoDB image around.
    cp /work/server/mongodb-linux-*/bin/mongod /rootfs/usr/local/bin/; \
    \
    sh_url="https://github.com/mongodb-js/mongosh/releases/download/v${MONGOSH_VERSION}/mongosh-${MONGOSH_VERSION}-linux-${sh_arch}-openssl3.tgz"; \
    echo "==> mongosh: ${sh_url}"; \
    curl -fsSL -o mongosh.tgz "${sh_url}"; \
    echo "${sh_sha}  mongosh.tgz" | sha256sum -c -; \
    mkdir -p /work/mongosh; \
    tar -xzf mongosh.tgz --strip-components=1 -C /work/mongosh; \
    # Copy only the mongosh binary. We skip mongosh_crypt_v1.so (about 112MB),
    # which is only needed for client-side field-level encryption inside the
    # shell. Leaving it out keeps the image noticeably smaller.
    cp -a /work/mongosh/bin/mongosh /rootfs/usr/local/bin/; \
    \
    chmod 0755 /rootfs/usr/local/bin/*; \
    ls -l /rootfs/usr/local/bin/


##############################################################################
# Stage 2: the actual runtime image, kept as small as we can.
##############################################################################
FROM ${BASE_IMAGE} AS final

ARG MONGO_VERSION
ARG MONGOSH_VERSION

# The libraries mongod links against (confirmed with `readelf -d mongod`), plus
# what mongosh needs. glibc, libresolv, libm and libc all come from the base.
USER root
RUN set -eux; \
    apk add --no-cache \
      bash \
      ca-certificates-bundle \
      libcrypto3 \
      libcurl-openssl4 \
      libgcc \
      libssl3 \
      libstdc++ \
      su-exec \
      tini \
      tzdata; \
    addgroup -g 999 mongodb; \
    adduser -u 999 -G mongodb -h /data/db -H -D -s /usr/bin/nologin mongodb; \
    mkdir -p /data/db /data/configdb /docker-entrypoint-initdb.d; \
    chown -R mongodb:mongodb /data/db /data/configdb

COPY --from=fetch /rootfs/ /
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# A quick sanity check that doubles as a linkage gate. Running each binary under
# `set -e` means that if any required shared library can't be resolved, the
# loader exits non-zero and the build fails right here instead of shipping.
RUN set -eux; \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh; \
    ln -s /usr/local/bin/docker-entrypoint.sh /docker-entrypoint.sh; \
    mongod --version; \
    mongosh --version

LABEL org.opencontainers.image.title="mongodb-slim" \
      org.opencontainers.image.description="The leanest maintained MongoDB Community Server image. Official binaries on Chainguard Wolfi (glibc), multi-arch, drop-in compatible with the official mongo image." \
      org.opencontainers.image.version="${MONGO_VERSION}" \
      org.opencontainers.image.source="https://github.com/Theofilos-Chamalis/mongodb-slim" \
      org.opencontainers.image.url="https://github.com/Theofilos-Chamalis/mongodb-slim" \
      org.opencontainers.image.documentation="https://github.com/Theofilos-Chamalis/mongodb-slim#readme" \
      org.opencontainers.image.vendor="mongodb-slim (community project, not affiliated with MongoDB, Inc.)" \
      org.opencontainers.image.licenses="SSPL-1.0" \
      org.mongodb-slim.mongosh.version="${MONGOSH_VERSION}"

VOLUME /data/db
EXPOSE 27017

# ping does not require auth, so this works with and without --auth
HEALTHCHECK --interval=10s --timeout=5s --start-period=45s --retries=6 \
  CMD mongosh --quiet --host 127.0.0.1 --eval "db.adminCommand('ping').ok" | grep -q 1 || exit 1

# tini is PID 1 so signals and zombie processes are handled properly. The
# entrypoint behaves like the official mongo image, including adding
# --bind_ip_all when you don't set your own bind option, so CMD is just mongod.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["mongod"]
