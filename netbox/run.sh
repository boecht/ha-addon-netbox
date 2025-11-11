#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH=${CONFIG_PATH:-/data/options.json}
PGDATA=${PGDATA:-/data/postgres}
REDIS_DATA_DIR=${REDIS_DATA_DIR:-/data/redis}
NETBOX_DATA_DIR=${NETBOX_DATA_DIR:-/data/netbox}
DB_SOCKET_DIR=/run/postgresql
NETBOX_USER=${NETBOX_USER:-netbox}
REDIS_CONF=/tmp/redis-netbox.conf

PATH="$(dirname "$(command -v pg_ctl)"):$PATH"
export PATH

detect_host_timezone() {
  if [[ -n "${TZ:-}" ]]; then
    printf %s "$TZ"
    return
  fi
  if [[ -f /etc/timezone ]]; then
    tr -d n < /etc/timezone
    return
  fi
  if [[ -L /etc/localtime ]]; then
    local target
    target=$(readlink -f /etc/localtime || true)
    if [[ -n "$target" ]]; then
      printf %s "${target#*/zoneinfo/}"
      return
    fi
  fi
  printf %s Etc/UTC
}

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$1"
}

fatal() {
  log "ERROR: $1"
  exit 1
}

read_option() {
  local key="$1" default_value="$2" value=""
  if [[ -s "$CONFIG_PATH" ]]; then
    value=$(jq -r --arg key "$key" '.[$key] // empty' "$CONFIG_PATH" 2>/dev/null || true)
  fi
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$value"
  fi
}

ensure_secret() {
  local provided="$1" file="$2" length="${3:-48}" secret
  if [[ -n "$provided" ]]; then
    secret="$provided"
  elif [[ -f "$file" && -s "$file" ]]; then
    secret="$(cat "$file")"
  else
    secret="$(head -c 64 /dev/urandom | base64 | tr -d '=\n' | cut -c1-"$length")"
    log "Generated new secret at $file"
  fi
  printf '%s' "$secret" > "$file"
  chmod 600 "$file"
  printf '%s' "$secret"
}

read_allowed_hosts() {
  local hosts=""
  if [[ -s "$CONFIG_PATH" ]]; then
    hosts=$(jq -r '.allowed_hosts // [] | map(select(. != null and . != "")) | join(",")' "$CONFIG_PATH" 2>/dev/null || true)
  fi
  if [[ -z "$hosts" ]]; then
    hosts="homeassistant.local,localhost,127.0.0.1"
  fi
  printf '%s' "$hosts"
}

read_plugins() {
  local plugins="[]"
  if [[ -s "$CONFIG_PATH" ]]; then
    plugins=$(jq -c '.plugins // []' "$CONFIG_PATH" 2>/dev/null || echo '[]')
  fi
  if [[ -z "$plugins" ]]; then
    plugins="[]"
  fi
  printf '%s' "$plugins"
}

ensure_directories() {
  mkdir -p "$PGDATA" "$REDIS_DATA_DIR" "$NETBOX_DATA_DIR"/media "$NETBOX_DATA_DIR"/reports "$NETBOX_DATA_DIR"/scripts
}

ensure_directories

chown -R postgres:postgres "$PGDATA" "$DB_SOCKET_DIR"
chown -R redis:redis "$REDIS_DATA_DIR"
chown -R "$NETBOX_USER":"$NETBOX_USER" "$NETBOX_DATA_DIR"

DB_NAME=$(read_option "db_name" "netbox")
DB_USER=$(read_option "db_user" "netbox")
DB_PASSWORD=$(ensure_secret "$(read_option "db_password" "")" "/data/.db_password")
SUPERUSER_USERNAME=$(read_option "superuser_username" "admin")
SUPERUSER_EMAIL=$(read_option "superuser_email" "admin@example.com")
SUPERUSER_PASSWORD=$(read_option "superuser_password" "")
SUPERUSER_TOKEN=$(ensure_secret "$(read_option "superuser_api_token" "")" "/data/.superuser_token" 64)
SECRET_KEY=$(ensure_secret "$(read_option "secret_key" "")" "/data/.secret_key" 64)
ALLOWED_HOSTS=$(read_allowed_hosts)
HOST_TZ=$(detect_host_timezone)
TIMEZONE=$(read_option "time_zone" "$HOST_TZ")
HOUSEKEEPING_INTERVAL=$(read_option "housekeeping_interval" "3600")
METRICS_ENABLED=$(read_option "enable_prometheus" "false")
PLUGINS=$(read_plugins)

if [[ -z "$SUPERUSER_PASSWORD" || "$SUPERUSER_PASSWORD" == "null" ]]; then
  fatal "superuser_password is required. Configure the add-on options before starting."
fi

PG_BIN_DIR=$(dirname "$(command -v initdb)")
INITDB="$PG_BIN_DIR/initdb"
PG_CTL="$PG_BIN_DIR/pg_ctl"

mkdir -p "$DB_SOCKET_DIR"
chown postgres:postgres "$DB_SOCKET_DIR"

if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  log "Initializing PostgreSQL data directory"
  gosu postgres "$INITDB" -D "$PGDATA" --encoding=UTF8 --locale=C
  cat > "$PGDATA/postgresql.conf" <<CONF
listen_addresses = '127.0.0.1'
port = 5432
unix_socket_directories = '$DB_SOCKET_DIR'
max_connections = 200
shared_buffers = 256MB
CONF
  cat > "$PGDATA/pg_hba.conf" <<HBA
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
HBA
fi

POSTGRES_STARTED=0
cleanup() {
  if [[ -n "${REDIS_PID:-}" ]] && kill -0 "$REDIS_PID" >/dev/null 2>&1; then
    log "Stopping Redis"
    kill "$REDIS_PID" >/dev/null 2>&1 || true
    wait "$REDIS_PID" 2>/dev/null || true
  fi
  if [[ "$POSTGRES_STARTED" -eq 1 ]]; then
    log "Stopping PostgreSQL"
    gosu postgres "$PG_CTL" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "Starting PostgreSQL"
gosu postgres "$PG_CTL" -D "$PGDATA" -o "-c config_file=$PGDATA/postgresql.conf" -w start
POSTGRES_STARTED=1

log "Ensuring NetBox database and role exist"
gosu postgres psql -v ON_ERROR_STOP=1 \\
  -v db_user="$DB_USER" \\
  -v db_password="$DB_PASSWORD" \\
  -v db_name="$DB_NAME" <<'SQL'
DO
$$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user') THEN
    EXECUTE format('CREATE ROLE %I LOGIN', :'db_user');
  END IF;
  EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password');
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', :'db_name', :'db_user');
  ELSE
    EXECUTE format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user');
  END IF;
END;
$$ LANGUAGE plpgsql;
SQL

gosu postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";" >/dev/null

log "Starting Redis"
cat > "$REDIS_CONF" <<CONF
bind 127.0.0.1
port 6379
dir $REDIS_DATA_DIR
save 60 1000
appendonly yes
protected-mode yes
loglevel warning
CONF
chown redis:redis "$REDIS_CONF"
chown -R redis:redis "$REDIS_DATA_DIR"
gosu redis redis-server "$REDIS_CONF" &
REDIS_PID=$!

for attempt in {1..30}; do
  if redis-cli -h 127.0.0.1 ping >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [[ $attempt -eq 30 ]]; then
    fatal "Redis did not become ready"
  fi
done

export DB_HOST=127.0.0.1
export DB_PORT=5432
export DB_NAME="$DB_NAME"
export DB_USER="$DB_USER"
export DB_PASSWORD="$DB_PASSWORD"
export DB_SSL=false
export REDIS_HOST=127.0.0.1
export REDIS_PORT=6379
export REDIS_PASSWORD=""
export REDIS_DATABASE=0
export REDIS_SSL=false
export CACHE_REDIS_HOST=127.0.0.1
export CACHE_REDIS_PORT=6379
export CACHE_REDIS_PASSWORD=""
export CACHE_REDIS_DATABASE=1
export CACHE_REDIS_SSL=false

export SECRET_KEY="$SECRET_KEY"
export ALLOWED_HOSTS="$ALLOWED_HOSTS"
export SUPERUSER_NAME="$SUPERUSER_USERNAME"
export SUPERUSER_EMAIL="$SUPERUSER_EMAIL"
export SUPERUSER_PASSWORD="$SUPERUSER_PASSWORD"
export DJANGO_SUPERUSER_PASSWORD="$SUPERUSER_PASSWORD"
export SUPERUSER_API_TOKEN="$SUPERUSER_TOKEN"
export DB_WAIT_TIMEOUT=60
export METRICS_ENABLED="$METRICS_ENABLED"
export HOUSEKEEPING_INTERVAL="$HOUSEKEEPING_INTERVAL"
export PLUGINS="$PLUGINS"
export TZ="$TIMEZONE"
export MEDIA_ROOT="$NETBOX_DATA_DIR/media"
export REPORTS_ROOT="$NETBOX_DATA_DIR/reports"
export SCRIPTS_ROOT="$NETBOX_DATA_DIR/scripts"

log "Launching NetBox via upstream entrypoint"
exec "$@"
