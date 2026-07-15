#!/usr/bin/env bash
#
# mongodb-slim entrypoint — behaviourally compatible with the official `mongo`
# image (docker-library/mongo). Supports:
#   - MONGO_INITDB_ROOT_USERNAME / _PASSWORD  (+ *_FILE secret variants)
#   - MONGO_INITDB_DATABASE
#   - /docker-entrypoint-initdb.d/*.sh and *.js executed on first init
#   - automatic --auth when a root user is bootstrapped
#   - dropping from root to the "mongodb" user
#
set -Eeuo pipefail

# If the first argument is a flag, assume the user wants mongod.
if [ "${1:-}" != "${1#-}" ]; then
	set -- mongod "$@"
fi

originalArgOne="${1:-}"

# Re-exec as the unprivileged mongodb user when started as root with mongod.
if [ "$originalArgOne" = 'mongod' ] && [ "$(id -u)" = '0' ]; then
	find /data/db /data/configdb \! -user mongodb -exec chown mongodb '{}' + 2>/dev/null || true
	exec su-exec mongodb "$0" "$@"
fi

# --- helpers ---------------------------------------------------------------

# file_env VAR [DEFAULT] — populate VAR from VAR or VAR_FILE (Docker secrets).
file_env() {
	local var="$1" fileVar="${1}_FILE" def="${2:-}"
	if [ -n "${!var:-}" ] && [ -n "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (only one allowed)"
		exit 1
	fi
	local val="$def"
	if [ -n "${!var:-}" ]; then
		val="${!var}"
	elif [ -n "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# _have_arg FLAG ARGS... — true if FLAG (or FLAG=...) is present.
_have_arg() {
	local target="$1"; shift
	local arg
	for arg in "$@"; do
		case "$arg" in
			"$target" | "$target"=*) return 0 ;;
		esac
	done
	return 1
}

# _get_arg_val FLAG ARGS... — echo the value of FLAG or FLAG=value.
_get_arg_val() {
	local target="$1"; shift
	local want=
	local arg
	for arg in "$@"; do
		if [ -n "$want" ]; then echo "$arg"; return; fi
		case "$arg" in
			"$target") want=1 ;;
			"$target"=*) echo "${arg#*=}"; return ;;
		esac
	done
}

# Wait until a local mongod answers ping (or time out).
_wait_for_mongod() {
	local port="$1" tries=0
	until mongosh --quiet --host "127.0.0.1:${port}" --eval 'db.adminCommand("ping").ok' 2>/dev/null | grep -q 1; do
		tries=$((tries + 1))
		if [ "$tries" -ge 60 ]; then
			echo >&2 "error: temporary mongod did not become ready in time"
			return 1
		fi
		sleep 1
	done
}

# --- init detection --------------------------------------------------------

needInit=
if [ "$originalArgOne" = 'mongod' ]; then
	dbPath="$(_get_arg_val --dbpath "$@")"
	dbPath="${dbPath:-/data/db}"

	file_env 'MONGO_INITDB_ROOT_USERNAME'
	file_env 'MONGO_INITDB_ROOT_PASSWORD'

	if [ -z "$(ls -A "$dbPath" 2>/dev/null || true)" ]; then
		needInit=1
	fi
fi

# --- first-run initialization ---------------------------------------------

if [ -n "$needInit" ]; then
	echo "mongodb-slim: initializing fresh dbPath ${dbPath}"

	tempPort=27017
	# Build temp-server args from the user's, minus networking/auth flags that
	# would interfere with local, unauthenticated bootstrapping.
	tempArgs=()
	skipNext=
	for arg in "$@"; do
		if [ -n "$skipNext" ]; then skipNext=; continue; fi
		case "$arg" in
			--auth | --bind_ip_all) continue ;;
			--bind_ip | --port) skipNext=1; continue ;;
			--bind_ip=* | --port=*) continue ;;
			*) tempArgs+=( "$arg" ) ;;
		esac
	done
	tempArgs+=( --bind_ip 127.0.0.1 --port "$tempPort" )

	"${tempArgs[@]}" &
	tempPid="$!"

	_wait_for_mongod "$tempPort"

	# Bootstrap the root user (server is unauthenticated at this point).
	if [ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ] && [ -n "${MONGO_INITDB_ROOT_PASSWORD:-}" ]; then
		echo "mongodb-slim: creating root user '${MONGO_INITDB_ROOT_USERNAME}'"
		MONGO_INITDB_ROOT_USERNAME="$MONGO_INITDB_ROOT_USERNAME" \
		MONGO_INITDB_ROOT_PASSWORD="$MONGO_INITDB_ROOT_PASSWORD" \
		mongosh --quiet --host "127.0.0.1:${tempPort}" admin --eval '
			db.createUser({
				user: process.env.MONGO_INITDB_ROOT_USERNAME,
				pwd:  process.env.MONGO_INITDB_ROOT_PASSWORD,
				roles: [ { role: "root", db: "admin" } ]
			});
		'
	fi

	# Run user-provided init scripts against MONGO_INITDB_DATABASE (or "test").
	initDb="${MONGO_INITDB_DATABASE:-test}"
	if [ -d /docker-entrypoint-initdb.d ]; then
		for f in /docker-entrypoint-initdb.d/*; do
			[ -e "$f" ] || continue
			case "$f" in
				*.sh)
					echo "mongodb-slim: running $f"
					# shellcheck disable=SC1090
					. "$f"
					;;
				*.js)
					echo "mongodb-slim: running $f"
					mongosh --quiet --host "127.0.0.1:${tempPort}" "$initDb" "$f"
					;;
				*)
					echo "mongodb-slim: ignoring $f"
					;;
			esac
		done
	fi

	# Cleanly stop the temporary server.
	echo "mongodb-slim: stopping temporary server"
	mongosh --quiet --host "127.0.0.1:${tempPort}" admin --eval 'db.shutdownServer()' >/dev/null 2>&1 || true
	wait "$tempPid" 2>/dev/null || true
	echo "mongodb-slim: initialization complete"
fi

# --- enable auth on the real server if we bootstrapped a user --------------

if [ "$originalArgOne" = 'mongod' ] \
	&& [ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ] \
	&& ! _have_arg --auth "$@" \
	&& ! _have_arg --noauth "$@"; then
	set -- "$@" --auth
fi

exec "$@"
