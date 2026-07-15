// Example first-run init script.
//
// Mount this directory read-only at /docker-entrypoint-initdb.d and it runs
// ONCE, the first time the container starts with an empty /data/db. `*.js`
// files run with mongosh against $MONGO_INITDB_DATABASE; `*.sh` files are sourced.
//
//   docker run -d \
//     -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=secret \
//     -e MONGO_INITDB_DATABASE=appdb \
//     -v "$PWD/examples/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d:ro" \
//     ghcr.io/OWNER/leanmongo:8
//
// NOTE: the server runs as uid 999, so mounted scripts must be world-readable.

const db = db.getSiblingDB('appdb');

db.createUser({
  user: 'app',
  pwd: 'app-password-change-me',
  roles: [{ role: 'readWrite', db: 'appdb' }],
});

db.widgets.insertOne({ createdBy: 'init-script', at: new Date() });
print('init: created app user and seeded appdb.widgets');
