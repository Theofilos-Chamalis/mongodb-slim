#!/usr/bin/env bash
#
# End-to-end smoke test for a LeanMongo image.
# Usage: test/smoke-test.sh <image> [expected_mongo_version]
#
# Exercises the behaviours users actually depend on and that determine parity
# with the official `mongo` image: startup, auth bootstrap, init scripts,
# non-root execution, clean linkage, TLS-capable OpenSSL, and persistence.
#
set -Eeuo pipefail

IMAGE="${1:?usage: smoke-test.sh <image> [expected_version]}"
EXPECTED_VERSION="${2:-}"

CID=""
INITDIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
	[ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1 || true
	rm -rf "$INITDIR"
}
trap cleanup EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# mongosh run inside the container (no host mongosh needed)
msh() { docker exec "$CID" mongosh --quiet "$@"; }

echo "== LeanMongo smoke test =="
echo "image: $IMAGE"

# An init script that must run exactly once, on first startup.
cat > "$INITDIR/seed.js" <<'JS'
db.getSiblingDB('appdb').widgets.insertMany([
  { _id: 1, name: 'alpha' },
  { _id: 2, name: 'beta'  },
]);
JS
# init scripts run as the unprivileged mongodb user (uid 999); make them readable
chmod -R a+rX "$INITDIR"

echo "-- starting container --"
CID="$(docker run -d \
	-e MONGO_INITDB_ROOT_USERNAME=root \
	-e MONGO_INITDB_ROOT_PASSWORD=trustno1 \
	-e MONGO_INITDB_DATABASE=appdb \
	-v "$INITDIR:/docker-entrypoint-initdb.d:ro" \
	-p 127.0.0.1:0:27017 \
	"$IMAGE")"

echo "-- waiting for health --"
deadline=$((SECONDS + 90))
status=""
while [ "$SECONDS" -lt "$deadline" ]; do
	status="$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo none)"
	[ "$status" = "healthy" ] && break
	if [ "$(docker inspect -f '{{.State.Running}}' "$CID")" != "true" ]; then
		echo "container exited early; logs:"; docker logs "$CID" | tail -30; exit 1
	fi
	sleep 2
done
[ "$status" = "healthy" ] && ok "container reached healthy state" || bad "container never became healthy (status=$status)"

# 1. version
ver="$(msh --host 127.0.0.1 --eval 'db.version()' | tr -d '\r')"
if [ -n "$EXPECTED_VERSION" ]; then
	[ "$ver" = "$EXPECTED_VERSION" ] && ok "server version $ver == expected" || bad "version $ver != expected $EXPECTED_VERSION"
else
	echo "  INFO: server version $ver"
fi

# 2. the mongod PROCESS runs as non-root (inspect /proc, not a fresh exec)
puid="$(docker exec "$CID" sh -c 'p=$(pgrep -o -x mongod); awk "/^Uid:/{print \$2}" /proc/$p/status' | tr -d '\r')"
[ "$puid" = "999" ] && ok "mongod process runs as non-root (uid=$puid)" || bad "expected mongod uid 999, got '$puid'"

# 3. binaries actually run on this base (proves clean dynamic linkage at runtime;
#    the Dockerfile also gates this with an explicit ldd check at build time)
if docker exec "$CID" mongod --version >/dev/null 2>&1 \
	&& docker exec "$CID" mongos --version >/dev/null 2>&1 \
	&& docker exec "$CID" mongosh --version >/dev/null 2>&1; then
	ok "mongod / mongos / mongosh all execute (linkage OK)"
else
	bad "one or more binaries failed to execute"
fi

# 4. OpenSSL 3 / TLS-capable build
ssl="$(msh --host 127.0.0.1 --eval 'db.serverBuildInfo().openssl.running' | tr -d '\r')"
echo "$ssl" | grep -qi 'OpenSSL 3' && ok "linked against OpenSSL 3 ($ssl)" || bad "unexpected OpenSSL: '$ssl'"

# 5. storage engine parity
se="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin \
	--eval 'db.serverStatus().storageEngine.name' | tr -d '\r')"
[ "$se" = "wiredTiger" ] && ok "storage engine is wiredTiger" || bad "storage engine is '$se'"

# 6. auth is actually enforced (unauthenticated write must fail)
if msh --host 127.0.0.1 --eval 'db.getSiblingDB("x").c.insertOne({a:1})' >/dev/null 2>&1; then
	bad "unauthenticated write succeeded (auth NOT enforced)"
else
	ok "unauthenticated write correctly rejected (auth enforced)"
fi

# 7. authenticated CRUD works
if msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin \
	--eval 'db.getSiblingDB("appdb").probe.insertOne({ok:1}); print(db.getSiblingDB("appdb").probe.countDocuments())' \
	| grep -q 1; then
	ok "authenticated CRUD works"
else
	bad "authenticated CRUD failed"
fi

# 8. init script ran (seed data present)
cnt="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin \
	--eval 'db.getSiblingDB("appdb").widgets.countDocuments()' | tr -d '\r')"
[ "$cnt" = "2" ] && ok "init script executed (2 seeded docs)" || bad "expected 2 seeded docs, got '$cnt'"

# 9. persistence across restart
docker restart "$CID" >/dev/null
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
	[ "$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null)" = "healthy" ] && break
	sleep 2
done
cnt2="$(msh --host 127.0.0.1 -u root -p trustno1 --authenticationDatabase admin \
	--eval 'db.getSiblingDB("appdb").widgets.countDocuments()' | tr -d '\r')"
[ "$cnt2" = "2" ] && ok "data persisted across restart" || bad "data lost across restart (got '$cnt2')"

echo
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
