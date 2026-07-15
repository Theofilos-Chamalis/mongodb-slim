# mongodb-slim

The leanest maintained MongoDB Community Server image on Docker Hub, built on [Chainguard Wolfi](https://github.com/wolfi-dev). It runs MongoDB's official binaries, works on both x86_64 and arm64, and behaves like the official `mongo` image, so you can drop it in without changing anything.

[![build-and-publish](https://github.com/Theofilos-Chamalis/mongodb-slim/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/Theofilos-Chamalis/mongodb-slim/actions/workflows/build-and-publish.yml)

> Unofficial community project. It is not affiliated with or endorsed by MongoDB, Inc. or Chainguard. MongoDB is a trademark of MongoDB, Inc. All this project does is repackage MongoDB's official, unmodified binaries. See [NOTICE.md](NOTICE.md).

## Why this exists

MongoDB doesn't publish an Alpine build, because the server isn't built for musl libc. So "MongoDB on Alpine" normally means either compiling it yourself or gluing a glibc shim onto Alpine, and neither is fun to maintain.

Wolfi avoids the whole problem. It's a minimal, apk-based distro that uses glibc, so MongoDB's official glibc binaries just run. Nothing is compiled, nothing is patched, and there's no shim in the way.

## How small is it

These are the compressed sizes, the number you actually download, measured from Docker Hub:

| Image | Compressed size |
|---|---|
| **mongodb-slim** | **~138 MB** |
| chainguard/mongodb | ~184 MB |
| bitnami/mongodb | ~269 MB |
| mongodb/mongodb-community-server | ~330 MB |
| official `mongo` | ~337 MB |

That makes it the leanest maintained MongoDB image we could find: smaller than every mainstream option, including Chainguard's, and about 40% of the size of the official `mongo` image. It gets there by building on Wolfi, keeping only the libraries `mongod` actually links against, and shipping just `mongod` and `mongosh` (no `mongos` sharding router, which a single-container setup never uses).

To be straight about it: this is not the tiniest MongoDB image that has ever existed. There are ancient 3.x and stripped-down community builds that are smaller. But among current, maintained, multi-arch images, nothing we compared beats it, and it does that without giving up `mongosh` or official-image compatibility.

## Quick start

```bash
docker run -d --name mongo -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=root \
  -e MONGO_INITDB_ROOT_PASSWORD=change-me \
  -v mongo-data:/data/db \
  ghcr.io/theofilos-chamalis/mongodb-slim:8

docker exec -it mongo mongosh -u root -p change-me
```

With Compose:

```yaml
services:
  mongo:
    image: ghcr.io/theofilos-chamalis/mongodb-slim:8
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

## Images and tags

Everything is published to GHCR, and to Docker Hub once that's configured:

- `ghcr.io/theofilos-chamalis/mongodb-slim:<tag>`
- `docker.io/theofxam/mongodb-slim:<tag>`

| Tag | Points to |
|---|---|
| `latest` | the newest tracked release (8.0.x right now) |
| `8`, `7` | the newest release in that major |
| `8.0`, `7.0` | the newest patch in that minor |
| `8.0.26`, `7.0.37`, ... | an exact version that never moves |

The tracked majors are MongoDB's currently supported LTS lines, set with `TRACKED_MAJORS` (default `8.0 7.0`). MongoDB 6.0 and older are end-of-life, so they're left out on purpose.

## Configuration

These match the official image, so existing setups keep working:

| Variable | What it does |
|---|---|
| `MONGO_INITDB_ROOT_USERNAME` / `_PASSWORD` | creates a root user on first start, which also turns on `--auth` |
| `MONGO_INITDB_ROOT_USERNAME_FILE` / `_PASSWORD_FILE` | reads those from a file, for Docker or Kubernetes secrets |
| `MONGO_INITDB_DATABASE` | the database that init scripts run against |

The first time the container starts with an empty `/data/db`, anything in `/docker-entrypoint-initdb.d` runs once. `.js` files run through `mongosh` and `.sh` files are sourced. Mount them read-only and make sure they're world-readable, since the server runs as uid 999. There's a working example in [`examples/`](examples/).

Anything you put after the image name is passed straight to `mongod` (and the entrypoint still adds `--bind_ip_all` for you, so this stays reachable):

```bash
docker run ghcr.io/theofilos-chamalis/mongodb-slim:8 mongod --replSet rs0
```

## Migrating from the official image

This is meant to be a straight swap. Point your `image:` at `mongodb-slim`, leave everything else alone, and it should just work. The parts people depend on behave the same:

- **Same environment variables:** `MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD`, `MONGO_INITDB_DATABASE`, plus the `_FILE` forms of the two credentials for Docker or Kubernetes secrets.
- **Same init directory:** `/docker-entrypoint-initdb.d`, with `.js` files run through `mongosh` and `.sh` files sourced, on the first start only.
- **Same auth behavior:** creating a root user from those variables turns on `--auth`, exactly like upstream.
- **Same networking:** `--bind_ip_all` is added for you unless you set your own bind option, so `docker run -p 27017:27017` works even when you override the command (for example `mongod --replSet rs0`).
- **Same command handling:** arguments after the image name go straight to `mongod`, and non-mongod commands like `mongosh` or `bash` run as-is.
- **Same layout:** data lives in `/data/db`, it listens on 27017, and it runs as a non-root user.

Each of these is checked on every build, on both amd64 and arm64, by [`test/smoke-test.sh`](test/smoke-test.sh), so they don't quietly regress.

Two differences worth knowing about:

- There is no `mongos` (the sharding-cluster router). A single-container deployment never runs it. If you specifically need a `mongos` node, run it from the official image.
- Bind address and dbPath are read from command-line flags, not from a YAML file passed with `--config`. If you use a config file that sets `net.bindIp` or `storage.dbPath`, pass those as flags too. `numactl` is also not used.

## Security

- It uses glibc directly, with no shims. The binaries are MongoDB's official ones, unmodified, and we pick the `ubuntu2404` or `ubuntu2204` build so they line up with Wolfi's OpenSSL 3.
- `mongod` runs as a normal user (`mongodb`, uid 999). The entrypoint drops root with `su-exec`.
- The image only carries what `mongod` actually links against (`libcurl`, `libssl3`, `libcrypto3`, `libgcc`), plus `mongosh`, `bash`, and `tini`. Nothing else.
- Every binary is checked against a published SHA-256 during the build, so a bad download fails the build instead of shipping.
- Images are published with an SBOM and build provenance.
- `tini` is PID 1, so signals and zombie processes are handled properly.

### One harmless warning you'll see

On startup you may see `mongod: /usr/lib/libcurl.so.4: no version information available`. It's cosmetic. Wolfi's libcurl doesn't carry Ubuntu's symbol-version tags, but all the symbols resolve and everything works. Only the version label is missing.

## How it stays current

- A daily job checks MongoDB's release feed and builds any new version that isn't published yet, so a new release usually shows up within a day without anyone doing anything.
- A weekly job rebuilds everything on the latest Wolfi base, so security fixes in the base flow through even when MongoDB itself hasn't changed.
- Both live in [`build-and-publish.yml`](.github/workflows/build-and-publish.yml), and the version picking is done by [`scripts/resolve-versions.py`](scripts/resolve-versions.py).

## How it's tested

Nothing gets published until it passes. Every version is built for both amd64 (on `ubuntu-latest`) and arm64 (on `ubuntu-24.04-arm`), natively, and run through [`test/smoke-test.sh`](test/smoke-test.sh). It exercises a real container end to end: it starts and goes healthy, reports the right version, runs as a non-root user, has clean library linkage, uses OpenSSL 3 and WiredTiger, and keeps its data across a restart. It also covers the official-image behaviors that make migration safe: enforced auth, authenticated reads and writes, both `.js` and `.sh` init scripts, `_FILE` secrets, automatic `--bind_ip_all`, and non-mongod command passthrough.

You can run the same test yourself:

```bash
docker build -t mongodb-slim:test .
./test/smoke-test.sh mongodb-slim:test 8.0.26
```

## Building it yourself

```bash
# current default (amd64)
docker buildx build --load -t mongodb-slim:test .

# a specific version (checksums come from scripts/resolve-versions.py)
docker buildx build --load -t mongodb-slim:7 \
  --build-arg MONGO_VERSION=7.0.37 \
  --build-arg MONGO_TARGET=ubuntu2204 \
  --build-arg MONGO_SHA256_AMD64=... \
  --build-arg MONGO_SHA256_ARM64=... .
```

## Licensing

MongoDB Community Server is under the SSPL, and `mongosh` is under Apache-2.0. The packaging in this repo (Dockerfile, scripts, workflows) is MIT, see [LICENSE](LICENSE). The details on redistribution and attribution are in [NOTICE.md](NOTICE.md).
