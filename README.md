# mongodb-slim 🍃

**Lean, secure, multi-arch MongoDB Community Server on [Chainguard Wolfi](https://github.com/wolfi-dev) (glibc).**
A drop-in-compatible alternative to the official `mongo` image — smaller, hardened, and published for **every** MongoDB version, free.

[![build-and-publish](https://github.com/OWNER/mongodb-slim/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/OWNER/mongodb-slim/actions/workflows/build-and-publish.yml)
[![watch-upstream](https://github.com/OWNER/mongodb-slim/actions/workflows/watch-upstream.yml/badge.svg)](https://github.com/OWNER/mongodb-slim/actions/workflows/watch-upstream.yml)

> **Unofficial community project.** Not affiliated with or endorsed by MongoDB, Inc. or Chainguard. MongoDB® is a trademark of MongoDB, Inc. This project only repackages MongoDB's official, unmodified server binaries. See [NOTICE.md](NOTICE.md).

---

## Why

MongoDB doesn't ship a musl/Alpine build, so "MongoDB on Alpine" usually means compiling from source or bolting a glibc shim onto Alpine. **Wolfi** sidesteps all of that: it's a minimal, `apk`-based, **glibc** undistro, so MongoDB's official glibc binaries run natively — no compilation, no shim.

| | mongodb-slim | official `mongo` | `chainguard/mongodb` |
|---|---|---|---|
| Base | Wolfi (glibc) | Ubuntu | Wolfi (glibc) |
| Image size (uncompressed) | ~815 MB | ~1.1 GB | small |
| Architectures | amd64 + arm64 | amd64 + arm64 | amd64 + arm64 |
| Runs as non-root | ✅ (uid 999) | ⚠️ root by default | ✅ |
| Official-image env vars / init scripts | ✅ | ✅ | ❌ (runs `mongod` directly) |
| Version-pinned tags, free | ✅ all tracked versions | ✅ | ⚠️ `:latest` only on free tier |
| SBOM + build provenance | ✅ | — | ✅ |
| Bundled `mongosh` | ✅ | ✅ | — |

## Quick start

```bash
docker run -d --name mongo -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=root \
  -e MONGO_INITDB_ROOT_PASSWORD=change-me \
  -v mongo-data:/data/db \
  ghcr.io/OWNER/mongodb-slim:8

# connect
docker exec -it mongo mongosh -u root -p change-me
```

`docker-compose.yml`:

```yaml
services:
  mongo:
    image: ghcr.io/OWNER/mongodb-slim:8
    restart: unless-stopped
    ports: ["27017:27017"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: root
      MONGO_INITDB_ROOT_PASSWORD_FILE: /run/secrets/mongo_root_pw
    secrets: [mongo_root_pw]
    volumes: ["mongo-data:/data/db"]
volumes: { mongo-data: {} }
secrets:
  mongo_root_pw: { file: ./mongo_root_pw.txt }
```

## Images & tags

Published to **GHCR** (always) and **Docker Hub** (when configured):

- `ghcr.io/OWNER/mongodb-slim:<tag>`
- `docker.io/DOCKERHUB_NS/mongodb-slim:<tag>`

| Tag | Points to |
|---|---|
| `latest` | newest tracked release (currently 8.0.x) |
| `8`, `7` | newest release in that major |
| `8.0`, `7.0` | newest patch in that minor |
| `8.0.26`, `7.0.37`, … | exact, immutable version |

Tracked majors are the currently-supported MongoDB LTS lines, configured via `TRACKED_MAJORS` (default `8.0 7.0`). MongoDB 6.0 and older are end-of-life and are intentionally not published.

## Configuration (compatible with the official image)

| Variable | Purpose |
|---|---|
| `MONGO_INITDB_ROOT_USERNAME` / `_PASSWORD` | create a root user on first start (enables `--auth`) |
| `MONGO_INITDB_ROOT_USERNAME_FILE` / `_PASSWORD_FILE` | read the above from a file (Docker/K8s secrets) |
| `MONGO_INITDB_DATABASE` | database that `/docker-entrypoint-initdb.d` scripts run against |

On **first** start with an empty `/data/db`, scripts in `/docker-entrypoint-initdb.d` run once:
`*.js` are executed with `mongosh`, `*.sh` are sourced. Mount them read-only, world-readable
(the server runs as uid 999). See [`examples/`](examples/).

Everything after the image name is passed straight to `mongod`, e.g.:

```bash
docker run ghcr.io/OWNER/mongodb-slim:8 mongod --replSet rs0 --bind_ip_all
```

## Security posture

- **glibc, no shims** — official binaries, unmodified; matched to Wolfi's **OpenSSL 3** by selecting the `ubuntu2404`/`ubuntu2204` build.
- **Non-root** — `mongod` runs as `mongodb` (uid 999); the entrypoint drops privileges via `su-exec`.
- **Minimal surface** — only the runtime libraries `mongod` actually links (`libcurl`, `libssl3`, `libcrypto3`, `libgcc`) plus `mongosh`, `bash`, `tini`.
- **Checksum-verified** — every binary is pinned by SHA-256 at build time; the build fails on mismatch.
- **Supply chain** — images ship with an SBOM and build provenance (`--sbom --provenance`).
- **`tini`** as PID 1 for correct signal handling and zombie reaping.

### Known cosmetic warning

`mongod: /usr/lib/libcurl.so.4: no version information available` on startup is **benign** — Wolfi's `libcurl` omits Ubuntu's symbol-version tags. All symbols resolve and every operation works; only the version annotation is absent.

## How it stays up to date

- **`watch-upstream`** runs daily, resolves the latest version per tracked major from MongoDB's release feed, and dispatches a build for any version not already on GHCR — so new images ship within a day of release.
- **`build-and-publish`** also runs weekly to rebuild on the latest Wolfi base, absorbing upstream CVE fixes even when MongoDB itself hasn't changed.
- Version/checksum resolution is deterministic — see [`scripts/resolve-versions.py`](scripts/resolve-versions.py).

## Validation

Every `(version, architecture)` pair is built **natively** (amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`) and must pass [`test/smoke-test.sh`](test/smoke-test.sh) before anything is published. The suite checks: healthy startup, exact version, non-root execution, clean linkage, OpenSSL 3, WiredTiger, enforced auth, authenticated CRUD, init-script execution, and data persistence across restart.

Run it locally against any tag:

```bash
docker build -t mongodb-slim:test .
./test/smoke-test.sh mongodb-slim:test 8.0.26
```

## Building locally

```bash
# amd64
docker buildx build --load -t mongodb-slim:test .

# a specific version (see scripts/resolve-versions.py for checksums)
docker buildx build --load -t mongodb-slim:7 \
  --build-arg MONGO_VERSION=7.0.37 \
  --build-arg MONGO_TARGET=ubuntu2204 \
  --build-arg MONGO_SHA256_AMD64=... \
  --build-arg MONGO_SHA256_ARM64=... .
```

## Licensing

MongoDB Community Server is distributed under the **SSPL**; `mongosh` under **Apache-2.0**. This repository's own tooling (Dockerfile, scripts, workflows) is **MIT** ([LICENSE](LICENSE)). Redistribution details and attribution are in [NOTICE.md](NOTICE.md).
