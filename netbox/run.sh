#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH=${CONFIG_PATH:-/data/options.json}
PGDATA=${PGDATA:-/data/postgres}
REDIS_DATA_DIR=${REDIS_DATA_DIR:-/data/redis}
NETBOX_DATA_DIR=${NETBOX_DATA_DIR:-/data/netbox}
DB_SOCKET_DIR=/run/postgresql
NETBOX_USER=${NETBOX_USER:-netbox}
REDIS_CONF=/tmp/redis-netbox.conf

unset PGDATABASE PGHOST PGPORT PGUSER PGSERVICE PGSERVICEFILE PGSSLMODE PGOPTIONS || true

wait_for_postgres() {
  local interval=${DB_WAIT_TIMEOUT:-1}
  local max=${MAX_DB_WAIT_TIME:-30}
  local waited=0
  while ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; do
    if (( waited >= max )); then
      fatal "PostgreSQL did not become ready within ${max}s"
    fi
    log "Waiting for PostgreSQL (${waited}s/${max}s)"
    sleep "$interval"
    waited=$((waited + interval))
  done
}

psql_admin() {
  local database="$1" uri
  shift
  uri="postgresql://postgres@127.0.0.1:5432/${database}"
  log "psql_admin: database=${database}"
  env -i \
    PATH="$PATH" \
    LANG="${LANG:-C.UTF-8}" \
    LC_ALL="${LC_ALL:-C.UTF-8}" \
    HOME=/var/lib/postgresql \
    PGHOST=127.0.0.1 \
    PGHOSTADDR=127.0.0.1 \
    PGPORT=5432 \
    PGDATABASE="$database" \
    PGUSER=postgres \
    PGSSLMODE=disable \
    PSQLRC=/dev/null \
    gosu postgres psql "$uri" -v ON_ERROR_STOP=1 "$@"
}

detect_host_timezone() {
  if [[ -n "${TZ:-}" ]]; then
    printf '%s' "$TZ"
    return
  fi
  if [[ -f /etc/timezone ]]; then
    tr -d '
' < /etc/timezone
    return
  fi
  if [[ -L /etc/localtime ]]; then
    local target
    target=$(readlink -f /etc/localtime || true)
    if [[ -n "$target" ]]; then
      printf '%s' "${target#*/zoneinfo/}"
      return
    fi
  fi
  printf '%s' 'Etc/UTC'
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
  local configured=""
  if [[ -s "$CONFIG_PATH" ]]; then
    configured=$(jq -r '.allowed_hosts // [] | map(select(. != null and . != "")) | join(",")' "$CONFIG_PATH" 2>/dev/null || true)
  fi
  if [[ -z "$configured" ]]; then
    printf '*'
  else
    printf '%s' "$configured"
  fi
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

add_pg_bin_dirs_to_path() {
  local glob dir
  shopt -s nullglob
  for glob in /usr/lib/postgresql/*/bin /usr/lib/postgresql/bin /usr/local/pgsql/bin; do
    for dir in $glob; do
      if [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]]; then
        PATH="$dir:$PATH"
      fi
    done
  done
  shopt -u nullglob
}

resolve_pg_binary() {
  local binary="$1" path=""
  if path=$(command -v "$binary" 2>/dev/null); then
    printf '%s' "$path"
    return 0
  fi
  add_pg_bin_dirs_to_path
  if path=$(command -v "$binary" 2>/dev/null); then
    printf '%s' "$path"
    return 0
  fi
  path=$(find /usr/lib/postgresql /usr/local/pgsql -maxdepth 4 -type f -name "$binary" -print -quit 2>/dev/null || true)
  if [[ -n "$path" ]]; then
    local dir
    dir=$(dirname "$path")
    if [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]]; then
      PATH="$dir:$PATH"
    fi
    printf '%s' "$path"
    return 0
  fi
  return 1
}

netbox_manage() {
  (cd /opt/netbox/netbox && /opt/netbox/venv/bin/python3 manage.py "$@")
}

ensure_superuser_exists() {
  netbox_manage shell --interface python <<'PY'
from django.contrib.auth import get_user_model
User = get_user_model()
username = "admin"
email = "admin@example.com"
password = "admin"
user, created = User.objects.get_or_create(username=username, defaults={"email": email})
if created:
    user.set_password(password)
    user.save()
    print("✅ Created default NetBox admin user (admin/admin)")
PY
}

clear_reset_flag() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    return
  fi
  local tmp
  tmp=$(mktemp)
  if jq '.reset_superuser = false' "$CONFIG_PATH" > "$tmp"; then
    mv "$tmp" "$CONFIG_PATH"
  else
    rm -f "$tmp"
    log "Failed to clear reset_superuser flag; please toggle it off manually."
  fi
}

reset_superuser_if_requested() {
  local flag="${RESET_SUPERUSER,,}"
  if [[ "$flag" != "true" ]]; then
    return
  fi
  log "Resetting NetBox admin credentials to admin/admin"
  netbox_manage shell --interface python <<'PY'
from django.contrib.auth import get_user_model
User = get_user_model()
username = "admin"
email = "admin@example.com"
password = "admin"
user, _ = User.objects.get_or_create(username=username)
user.email = email
user.is_active = True
user.set_password(password)
user.save()
print("✅ NetBox admin credentials reset; please change them inside NetBox.")
PY
  clear_reset_flag
}

warn_default_token() {
  netbox_manage shell --interface python <<'PY'
from users.models import Token
try:
    Token.objects.get(key="0123456789abcdef0123456789abcdef01234567")
except Token.DoesNotExist:
    pass
else:
    print("⚠️  Warning: default admin API token still present; delete it via the NetBox UI.")
PY
}

run_housekeeping_if_needed() {
  if netbox_manage migrate --check >/dev/null 2>&1; then
    return
  fi
  log "Applying database migrations"
  netbox_manage migrate --no-input
  log "Running trace_paths"
  netbox_manage trace_paths --no-input
  log "Removing stale content types"
  netbox_manage remove_stale_contenttypes --no-input
  log "Removing expired sessions"
  netbox_manage clearsessions
  log "Building search index (lazy)"
  netbox_manage reindex --lazy
}

ensure_directories() {
  mkdir -p "$PGDATA" "$REDIS_DATA_DIR" "$NETBOX_DATA_DIR"/media "$NETBOX_DATA_DIR"/reports "$NETBOX_DATA_DIR"/scripts
}

ensure_directories

chown -R postgres:postgres "$PGDATA" "$DB_SOCKET_DIR"
chown -R redis:redis "$REDIS_DATA_DIR"
chown -R "$NETBOX_USER":"$NETBOX_USER" "$NETBOX_DATA_DIR"

DB_NAME="netbox"
DB_USER="netbox"
DB_PASSWORD=$(ensure_secret "" "/data/.db_password")
RESET_SUPERUSER=$(read_option "reset_superuser" "false")
SECRET_KEY=$(ensure_secret "$(read_option "secret_key" "")" "/data/.secret_key" 64)
ALLOWED_HOSTS=$(read_allowed_hosts)
HOST_TZ=$(detect_host_timezone)
TIMEZONE="$HOST_TZ"
HOUSEKEEPING_INTERVAL=$(read_option "housekeeping_interval" "3600")
METRICS_ENABLED=$(read_option "enable_prometheus" "false")
PLUGINS=$(read_plugins)
DB_WAIT_TIMEOUT=${DB_WAIT_TIMEOUT:-1}
MAX_DB_WAIT_TIME=${MAX_DB_WAIT_TIME:-30}

add_pg_bin_dirs_to_path

PG_CTL_PATH=$(resolve_pg_binary pg_ctl || true)
if [[ -z "$PG_CTL_PATH" ]]; then
  fatal "pg_ctl not found; ensure PostgreSQL binaries are installed."
fi

PG_BIN_DIR=$(dirname "$PG_CTL_PATH")
if [[ ":$PATH:" != *":$PG_BIN_DIR:"* ]]; then
  PATH="$PG_BIN_DIR:$PATH"
fi
export PATH

INITDB=$(resolve_pg_binary initdb || true)
if [[ -z "$INITDB" ]]; then
  fatal "initdb not found; ensure PostgreSQL binaries are installed."
fi

PG_CTL="$PG_CTL_PATH"

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
wait_for_postgres

log "Ensuring NetBox database and role exist"
psql_admin postgres \
  -v db_user="$DB_USER" \
  -v db_password="$DB_PASSWORD" \
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

psql_admin "$DB_NAME" \
  -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";" >/dev/null

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
export SKIP_SUPERUSER=true
export DB_WAIT_TIMEOUT=1
export MAX_DB_WAIT_TIME=30
export METRICS_ENABLED="$METRICS_ENABLED"
export HOUSEKEEPING_INTERVAL="$HOUSEKEEPING_INTERVAL"
export PLUGINS="$PLUGINS"
export TZ="$TIMEZONE"
export MEDIA_ROOT="$NETBOX_DATA_DIR/media"
export REPORTS_ROOT="$NETBOX_DATA_DIR/reports"
export SCRIPTS_ROOT="$NETBOX_DATA_DIR/scripts"

run_housekeeping_if_needed
ensure_superuser_exists
reset_superuser_if_requested
warn_default_token

log "Launching NetBox via upstream entrypoint"
exec "$@"
