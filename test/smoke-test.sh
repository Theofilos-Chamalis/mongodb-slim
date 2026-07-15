#!/usr/bin/env bash
#
# End-to-end smoke test for a mongodb-slim image.
# Usage: test/smoke-test.sh <image> [expected_mongo_version]
#
# It runs a real container and checks the things people actually rely on, plus
# the behaviors that make this a drop-in replacement for the official mongo
# image: startup, the version, non-root execution, clean library linkage,
# OpenSSL 3, WiredTiger, auth, .js and .sh init scripts, --bind_ip_all, _FILE
# secrets, non-mongod command passthrough, and data surviving a restart.
#
set -Eeuo pipefail

IMAGE="${1:?usage: smoke-test.sh <image> [expected_version]}"
EXPECTED_VERSION="${2:-}"

CID=""
CID_FILE=""
INITDIR="$(mktemp -d)"
SECRETDIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
	[ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1 || true
	[ -n "$CID_FILE" ] && docker rm -f "$CID_FILE" >/dev/null 2>&1 || true
	rm -rf "$INITDIR" "$SECRETDIR"
}
trap cleanup EXIT

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# mongosh, run inside the main container so we don't need it on the host
msh() { docker exec "$CID" mongosh --quiet "$@"; }

wait_healthy() {
	local cid="$1"
	local limit="${2:-90}"
	local deadline=$((SECONDS + limit))
	while [ "$SECONDS" -lt "$deadline" ]; do
		[ "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo none)" = healthy ] && return 0
		if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != true ]; then
			echo "container $cid exited early; logs:"; docker logs "$cid" | tail -30; return 1
		fi
		sleep 2
	done
	return 1
}

echo "== mongodb-slim smoke test =="
echo "image: $IMAGE"

# Two init scripts that must each run exactly once on first start: one .js and
# one .sh, so we cover both file types the official image supports.
cat > "$INITDIR/seed.js" <<'JS'
db.getSiblingDB('appdb').widgets.insertMany([
  { _id: 1, name: 'alpha' },
  { _id: 2, name: 'beta'  },
]);
JS
cat > "$INITDIR/seed.sh" <<'SH'
mongosh --quiet --host 127.0.0.1:27017 appdb --eval 'db.fromsh.insertOne({ ok: 1 })'
SH
# init scripts run as the unprivileged mongodb user (uid 999), so make them readable
chmod -R a+rX "$INITDIR"

echo "-- starting main container --"
CID="$(docker run -d \
	-e MONGO_INITDB_ROOT_USERNAME=root \
	-e MONGO_INITDB_ROOT_PASSWORD=trustno1 \
	-e MONGO_INITDB_DATABASE=appdb \
	-v "$INITDIR:/docker-entrypoint-initdb.d:ro" \
	-p 127.0.0.1:0:27017 \
	"$IMAGE")"

echo "-- waiting for health --"
wait_healthy "$CID" 90 && ok "container reached healthy state" || bad "container never became healthy"

# version
ver="$(msh --host 127.0.0.1 --eval 'db.version()' | tr -d '\r')"
if [ -n "$EXPECTED_VERSION" ]; then
	[ "$ver" = "$EXPECTED_VERSION" ] && ok "server version $ver == expected" || bad "version $ver != expected $EXPECTED_VERSION"
else
	echo "  INFO: server version $ver"
fi

# the mongod process runs as a non-root user (read /proc, not a fresh exec)
puid="$(docker exec "$CID" sh -c 'p=$(pgrep -o -x mongod); awk "/^Uid:/{print \$2}" /proc/$p/status' | tr -d '\r')"
[ "$puid" = "999" ] && ok "mongod process runs as non-root (uid=$puid)" || bad "expected mongod uid 999, got '$puid'"

# the binaries actually run on this base (a real check of dynamic linkage)
if docker exec "$CID" mongod --version >/dev/null 2>&1 && docker exec "$CID" mongosh --version >/dev/null 2>&1; then
	ok "mongod and mongosh both execute (linkage OK)"
else
	bad "mongod or mongosh failed to execute"
fi

# OpenSSL 3, so TLS is available
ssl="$(msh --host 127.0.0.1 --eval 'db.serverBuildInfo().openssl.running' | tr -d '\r')"
echo "$ssl" | grep -qi 'OpenSSL 3' && ok "linked against OpenSSL 3 ($ssl)" || bad "unexpected OpenSSL: '$ssl'"

# storage engine
se="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin --eval 'db.serverStatus().storageEngine.name' | tr -d '\r')"
[ "$se" = "wiredTiger" ] && ok "storage engine is wiredTiger" || bad "storage engine is '$se'"

# auth is enforced: an unauthenticated write must fail
if msh --host 127.0.0.1 --eval 'db.getSiblingDB("x").c.insertOne({a:1})' >/dev/null 2>&1; then
	bad "unauthenticated write succeeded (auth NOT enforced)"
else
	ok "unauthenticated write correctly rejected (auth enforced)"
fi

# authenticated reads and writes work
if msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin \
	--eval 'db.getSiblingDB("appdb").probe.insertOne({ok:1}); print(db.getSiblingDB("appdb").probe.countDocuments())' | grep -q 1; then
	ok "authenticated CRUD works"
else
	bad "authenticated CRUD failed"
fi

# the .js init script ran
jcnt="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin --eval 'db.getSiblingDB("appdb").widgets.countDocuments()' | tr -d '\r')"
[ "$jcnt" = "2" ] && ok ".js init script ran (2 seeded docs)" || bad "expected 2 docs from seed.js, got '$jcnt'"

# the .sh init script ran
scnt="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin --eval 'db.getSiblingDB("appdb").fromsh.countDocuments()' | tr -d '\r')"
[ "$scnt" = "1" ] && ok ".sh init script ran (1 doc)" || bad "expected 1 doc from seed.sh, got '$scnt'"

# the entrypoint added --bind_ip_all, like the official image
argv="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin --eval 'db.adminCommand({getCmdLineOpts:1}).argv.join(" ")')"
echo "$argv" | grep -q -- '--bind_ip_all' && ok "entrypoint added --bind_ip_all (reachable via published port)" || bad "--bind_ip_all not applied (argv: $argv)"

# a non-mongod command runs as-is, with no init side effects
if docker run --rm "$IMAGE" mongosh --version >/dev/null 2>&1; then
	ok "non-mongod command passthrough works (mongosh --version)"
else
	bad "non-mongod command passthrough failed"
fi

# data survives a restart
docker restart "$CID" >/dev/null
wait_healthy "$CID" 60 >/dev/null || true
rcnt="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin --eval 'db.getSiblingDB("appdb").widgets.countDocuments()' | tr -d '\r')"
[ "$rcnt" = "2" ] && ok "data persisted across restart" || bad "data lost across restart (got '$rcnt')"

# _FILE secrets: the root password can come from a mounted file
echo "-- starting _FILE-secret container --"
printf 'filesecret123' > "$SECRETDIR/mongo_pw"
chmod -R a+rX "$SECRETDIR"
CID_FILE="$(docker run -d \
	-e MONGO_INITDB_ROOT_USERNAME=root \
	-e MONGO_INITDB_ROOT_PASSWORD_FILE=/run/secrets/mongo_pw \
	-v "$SECRETDIR/mongo_pw:/run/secrets/mongo_pw:ro" \
	"$IMAGE")"
if wait_healthy "$CID_FILE" 90 \
	&& docker exec "$CID_FILE" mongosh --quiet -u root -p filesecret123 --authenticationDatabase admin --eval 'db.adminCommand("ping").ok' | grep -q 1; then
	ok "_FILE secret honored (auth works with password from file)"
else
	bad "_FILE secret not honored"
fi

echo
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
