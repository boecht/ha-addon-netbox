#!/usr/bin/env bash
# NetBox Home Assistant add-on entrypoint: brings up PostgreSQL, Redis, and the upstream
# NetBox stack inside one container while honoring Supervisor configuration.
set -euo pipefail

# Logging & instrumentation
LOG_LEVEL=${LOG_LEVEL:-debug}

# Configuration files
CONFIG_PATH=${CONFIG_PATH:-/data/options.json}
PLUGINS_CONFIG_PATH=/etc/netbox/config/99-ha-addon-plugins.py

# Filesystem paths
DB_SOCKET_DIR=/run/postgresql
NETBOX_DATA_DIR=${NETBOX_DATA_DIR:-/data/netbox}
PGDATA=${PGDATA:-/data/postgres}
REDIS_CONF=/tmp/redis-netbox.conf
REDIS_DATA_DIR=${REDIS_DATA_DIR:-/data/redis}

# Runtime defaults
DEFAULT_PLUGINS_JSON='["netbox_napalm_plugin","netbox_ping","netbox_topology_views"]'
DEFAULT_SUPERUSER_FLAG=/data/.superuser_initialized
NETBOX_USER=${NETBOX_USER:-netbox}

_log() {
    local message="$1"
    local level="${2:-INFO}"
    printf '[%s] %s %s\n' "$(date --iso-8601=seconds)" "$level" "$message"
}

log_critical() {
    _log "$1" "CRITICAL"
    trap - ERR
    exit 1
}

log_error() {
    _log "$1" "ERROR"
}

log_warn() {
    _log "$1" "WARN"
}

log_info() {
    _log "$1" "INFO"
}

log_debug() {
    if [[ "${LOG_LEVEL,,}" == "debug" ]]; then
        _log "$1" "DEBUG"
    fi
}

log_new_section() {
    local title="$1"
    _log "==> $title" "STEP"
}

handle_unexpected_error() {
    local exit_code=$?
    local cmd=${BASH_COMMAND:-unknown}
    local line=${BASH_LINENO[0]:-0}
    trap - ERR
    log_error "Unexpected error (exit ${exit_code}) at line ${line} while running: ${cmd}"
    exit "$exit_code"
}
trap handle_unexpected_error ERR

run_checked() {
    local description="$1"
    shift
    if ! "$@"; then
        local status=$?
        log_critical "${description} failed with exit code ${status}"
    fi
}

run_warn() {
    local description="$1"
    shift
    if ! "$@"; then
        local status=$?
        log_warn "${description} failed with exit code ${status}"
        return 0
    fi
}

existing_pg_env=$(env | grep '^PG' || true)
if [[ -n "$existing_pg_env" ]]; then
    log_debug "Inherited PG environment before cleanup:\n$existing_pg_env"
else
    log_debug "No inherited PG* variables detected before cleanup."
fi

unset PGDATABASE PGHOST PGPORT PGUSER PGSERVICE PGSERVICEFILE PGSSLMODE PGOPTIONS PGPASSFILE || true
log_debug "PG* environment after cleanup: $(env | grep '^PG' || echo '<none>')"

SCRIPT_SOURCE=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$0")
if [[ -f "$SCRIPT_SOURCE" ]]; then
    SCRIPT_SHA=$(sha256sum "$SCRIPT_SOURCE" | awk '{print $1}')
    log_debug "Addon run script: $SCRIPT_SOURCE (sha256=$SCRIPT_SHA)"
fi

if command -v psql >/dev/null 2>&1; then
    log_debug "psql binary: $(command -v psql)"
    log_debug "psql version: $(psql --version 2>&1)"
else
    log_warn "psql binary not found in PATH=$PATH"
fi

wait_for_postgres() {
    local interval=1
    local max=30
    local waited=0
    while ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; do
        if (( waited >= max )); then
            log_critical "PostgreSQL did not become ready within ${max}s"
        fi
        log_info "Waiting for PostgreSQL (${waited}s/${max}s)"
        sleep "$interval"
        waited=$((waited + interval))
    done
}

sql_escape_literal() {
    local input=${1//\'/\'\'}
    printf '%s' "$input"
}

psql_admin() {
    local database="$1" socket_host
    shift
    socket_host="$DB_SOCKET_DIR"
    log_debug "psql_admin: database=${database}, args=$*"
    if ! env -i \
    PATH="$PATH" \
    LANG="${LANG:-C.UTF-8}" \
    LC_ALL="${LC_ALL:-C.UTF-8}" \
    HOME=/var/lib/postgresql \
    PGHOST="$socket_host" \
    PGPORT=5432 \
    PGDATABASE="$database" \
    PGUSER=postgres \
    PGAPPNAME="ha-addon-netbox" \
    PGSSLMODE=disable \
    PGSERVICEFILE=/dev/null \
    PGCONNECT_TIMEOUT=10 \
    PSQLRC=/dev/null \
    gosu postgres psql -h "$socket_host" -p 5432 -U postgres -v ON_ERROR_STOP=1 -d "$database" "$@"
    then
        log_error "psql_admin failed for database=${database} (args: $*)"
        return 1
    fi
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

write_postgres_conf() {
    local tz_escaped=${TIMEZONE//\'/\'\'}
    log_debug "Writing PostgreSQL config with timezone=${TIMEZONE}"
  cat > "$PGDATA/postgresql.conf" <<CONF
listen_addresses = '127.0.0.1'
port = 5432
unix_socket_directories = '$DB_SOCKET_DIR'
max_connections = 200
shared_buffers = 256MB
timezone = '$tz_escaped'
CONF
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
        log_debug "Reusing secret from $file"
        secret="$(cat "$file")"
    else
        secret="$(head -c 64 /dev/urandom | base64 | tr -d '=\n' | cut -c1-"$length")"
        log_info "Generated new secret at $file"
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
    if [[ -z "$plugins" || "$plugins" == "null" ]]; then
        plugins="$DEFAULT_PLUGINS_JSON"
    fi
    printf '%s' "$plugins"
}

write_plugins_config() {
    local plugin_json="$1" plugin_config_json="$2"
    mkdir -p /etc/netbox/config
    log_debug "Writing plugin config to $PLUGINS_CONFIG_PATH: $plugin_json with config $plugin_config_json"
  cat > "$PLUGINS_CONFIG_PATH" <<PY
PLUGINS = $plugin_json
PLUGINS_CONFIG = $plugin_config_json
PY
    log_debug "Plugin config file contents:\n$(cat "$PLUGINS_CONFIG_PATH" 2>/dev/null || echo '<missing>')"
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
    if [[ -f "$DEFAULT_SUPERUSER_FLAG" ]]; then
        log_debug "Default superuser already initialized"
        return
    fi
  if ! netbox_manage shell --interface python <<'PY'
from django.contrib.auth import get_user_model
User = get_user_model()
username = "admin"
email = "admin@example.com"
password = "admin"
user, created = User.objects.get_or_create(username=username, defaults={"email": email})
if created:
    user.set_password(password)
user.is_active = True
user.is_staff = True
user.is_superuser = True
user.email = email
user.save()
print("✅ Created default NetBox admin user (admin/admin)")
PY
    then
        log_critical "Failed to create default NetBox admin user"
    fi
    touch "$DEFAULT_SUPERUSER_FLAG"
}

reset_superuser_if_requested() {
    local flag="${RESET_SUPERUSER,,}"
    if [[ "$flag" != "true" ]]; then
        return
    fi
    log_info "Resetting NetBox admin credentials to admin/admin"
  if ! netbox_manage shell --interface python <<'PY'
from django.contrib.auth import get_user_model
User = get_user_model()
username = "admin"
email = "admin@example.com"
password = "admin"
user, _ = User.objects.get_or_create(username=username)
user.email = email
user.is_active = True
user.is_staff = True
user.is_superuser = True
user.set_password(password)
user.save()
print("✅ NetBox admin credentials reset; please change them inside NetBox.")
PY
    then
        log_critical "Failed to reset NetBox admin credentials"
    fi
    log_info "Reset complete; please toggle reset_superuser off in the add-on UI."
}

log_active_plugins() {
    log_debug "Querying NetBox for active plugin list"
  run_warn "Reading NetBox settings.PLUGINS" netbox_manage shell --interface python <<'PY'
from django.conf import settings
print("Active plugins:", settings.PLUGINS)
PY
}

run_housekeeping_if_needed() {
    if netbox_manage migrate --check >/dev/null 2>&1; then
        return
    fi
    log_info "Applying database migrations"
    run_checked "netbox_manage migrate" netbox_manage migrate --no-input
    log_info "Running trace_paths"
    run_checked "netbox_manage trace_paths" netbox_manage trace_paths --no-input
    log_info "Removing stale content types"
    run_checked "netbox_manage remove_stale_contenttypes" netbox_manage remove_stale_contenttypes --no-input
    log_info "Removing expired sessions"
    run_checked "netbox_manage clearsessions" netbox_manage clearsessions
    log_info "Building search index (lazy)"
    run_checked "netbox_manage reindex --lazy" netbox_manage reindex --lazy
}

ensure_directories() {
    mkdir -p "$PGDATA" "$REDIS_DATA_DIR" "$NETBOX_DATA_DIR"/media "$NETBOX_DATA_DIR"/reports "$NETBOX_DATA_DIR"/scripts "$DB_SOCKET_DIR"
}

log_new_section "Preparing persistent directories"
ensure_directories

chown -R postgres:postgres "$PGDATA" "$DB_SOCKET_DIR"
chown -R redis:redis "$REDIS_DATA_DIR"
chown -R "$NETBOX_USER":"$NETBOX_USER" "$NETBOX_DATA_DIR"

log_debug "Directory ownership prepared (postgres, redis, $NETBOX_USER)"

log_new_section "Loading add-on options"
DB_NAME="netbox"
DB_USER="netbox"
DB_PASSWORD=$(ensure_secret "" "/data/.db_password")
RESET_SUPERUSER=$(read_option "reset_superuser" "false")
DEBUG_LOGGING=$(read_option "debug_logging" "true")
if [[ "${DEBUG_LOGGING,,}" == "true" ]]; then
    LOG_LEVEL="debug"
else
    LOG_LEVEL="info"
fi
log_info "Log level set to ${LOG_LEVEL^^} (debug_logging=${DEBUG_LOGGING,,})"
SECRET_KEY=$(ensure_secret "" "/data/.secret_key" 64)
ALLOWED_HOSTS=$(read_allowed_hosts)
HOST_TZ=$(detect_host_timezone)
TIMEZONE="$HOST_TZ"
HOUSEKEEPING_INTERVAL=$(read_option "housekeeping_interval" "3600")
METRICS_ENABLED=$(read_option "enable_prometheus" "false")
PLUGINS=$(read_plugins)
NAPALM_USERNAME=$(read_option "napalm_username" "")
NAPALM_PASSWORD=$(read_option "napalm_password" "")
NAPALM_TIMEOUT=$(read_option "napalm_timeout" "30")
NAPALM_TIMEOUT=${NAPALM_TIMEOUT:-30}
log_debug "Plugins list resolved from config: $PLUGINS"
NAPALM_PLUGIN_CONFIG='{}'
if jq -e 'index("netbox_napalm_plugin")' <<<"$PLUGINS" >/dev/null 2>&1; then
    if [[ -z "$NAPALM_USERNAME" ]]; then
        log_critical "napalm_username option is required when netbox_napalm_plugin is enabled."
    fi
    NAPALM_PLUGIN_CONFIG=$(jq -n --arg u "$NAPALM_USERNAME" --arg p "$NAPALM_PASSWORD" --argjson t "$NAPALM_TIMEOUT" '{
      ("netbox_napalm_plugin"): ({NAPALM_USERNAME: $u}
        + (if ($p | length) > 0 then {NAPALM_PASSWORD: $p} else {} end)
        + {NAPALM_TIMEOUT: $t})
    }')
fi
write_plugins_config "$PLUGINS" "$NAPALM_PLUGIN_CONFIG"
log_debug "Database config: DB_NAME=$DB_NAME DB_USER=$DB_USER PGDATA=$PGDATA socket_dir=$DB_SOCKET_DIR"

add_pg_bin_dirs_to_path

PG_CTL_PATH=$(resolve_pg_binary pg_ctl || true)
if [[ -z "$PG_CTL_PATH" ]]; then
    log_critical "pg_ctl not found; ensure PostgreSQL binaries are installed."
fi

PG_BIN_DIR=$(dirname "$PG_CTL_PATH")
if [[ ":$PATH:" != *":$PG_BIN_DIR:"* ]]; then
    PATH="$PG_BIN_DIR:$PATH"
fi
export PATH

INITDB=$(resolve_pg_binary initdb || true)
if [[ -z "$INITDB" ]]; then
    log_critical "initdb not found; ensure PostgreSQL binaries are installed."
fi

PG_CTL="$PG_CTL_PATH"

mkdir -p "$DB_SOCKET_DIR"
chown postgres:postgres "$DB_SOCKET_DIR"

if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    log_new_section "Initializing PostgreSQL data directory"
    gosu postgres "$INITDB" -D "$PGDATA" --encoding=UTF8 --locale=C
    write_postgres_conf
  cat > "$PGDATA/pg_hba.conf" <<HBA
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
HBA
fi

POSTGRES_STARTED=0
cleanup() {
    if [[ -n "${REDIS_PID:-}" ]] && kill -0 "$REDIS_PID" >/dev/null 2>&1; then
        log_info "Stopping Redis"
        kill "$REDIS_PID" >/dev/null 2>&1 || true
        wait "$REDIS_PID" 2>/dev/null || true
    fi
    if [[ "$POSTGRES_STARTED" -eq 1 ]]; then
        log_info "Stopping PostgreSQL"
        gosu postgres "$PG_CTL" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

log_new_section "Starting PostgreSQL"
gosu postgres "$PG_CTL" -D "$PGDATA" -o "-c config_file=$PGDATA/postgresql.conf" -w start
POSTGRES_STARTED=1
wait_for_postgres

log_new_section "Provisioning NetBox database"
log_debug "Ensuring NetBox DB roles via psql_admin"
db_user_literal=$(sql_escape_literal "$DB_USER")
db_password_literal=$(sql_escape_literal "$DB_PASSWORD")
db_name_literal=$(sql_escape_literal "$DB_NAME")
if ! psql_admin postgres <<SQL
DO
\$\$
DECLARE
  db_user text := '$db_user_literal';
  db_password text := '$db_password_literal';
  db_name text := '$db_name_literal';
  db_exists boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = db_user) THEN
    EXECUTE format('CREATE ROLE %I LOGIN', db_user);
  END IF;
  EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', db_user, db_password);

  SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = db_name) INTO db_exists;
  IF NOT db_exists THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', db_name, db_user);
  ELSE
    EXECUTE format('ALTER DATABASE %I OWNER TO %I', db_name, db_user);
  END IF;
END;
\$\$ LANGUAGE plpgsql;
SQL
then
    log_critical "Failed to provision NetBox database and roles"
fi

log_debug "Applying DB grants via psql_admin"
if ! psql_admin "$DB_NAME" \
    -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";" >/dev/null
then
    log_critical "Failed to grant privileges to NetBox database user"
fi

log_new_section "Starting Redis"
cat > "$REDIS_CONF" <<CONF
bind 127.0.0.1
port 6379
dir $REDIS_DATA_DIR
save 60 1000
appendonly yes
protected-mode yes
loglevel warning
ignore-warnings ARM64-COW-BUG
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
        log_critical "Redis did not become ready"
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

log_new_section "Running NetBox maintenance tasks"
run_housekeeping_if_needed
ensure_superuser_exists
reset_superuser_if_requested
log_active_plugins

log_new_section "Launching NetBox"
exec "$@"
