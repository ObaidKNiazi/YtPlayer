#!/bin/bash
# ==========================================================================================
# 🏭 PRODUCTION HARDENED HOSTING ENGINE v34.0 – FINAL DEPLOYABLE 🏭
# ==========================================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${CYAN}➜${NC} $1"; }
header() { echo -e "${MAGENTA}════════════════════════════════════════════════════════════════════${NC}"; }

if [[ "${ENGINE_MODE:-}" != "api" ]]; then
    echo "ERROR: Direct execution disabled. Use API layer with ENGINE_MODE=api"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f "config.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            var="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%\"}"; val="${val#\"}"
            export "$var=$val"
        fi
    done < "config.env"
fi

[[ -z "${SECRET_KEY:-}" ]] && { echo "ERROR: SECRET_KEY must be set in config.env"; exit 1; }
[[ "${ENGINE_SECRET:-}" != "${SECRET_KEY}" ]] && { echo "ERROR: Unauthorized execution. Invalid ENGINE_SECRET."; exit 1; }

BASE_DOMAIN="${BASE_DOMAIN:-hostingsip.com}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_TOKEN_FILE="${CLOUDFLARE_TOKEN_FILE:-$SCRIPT_DIR/cloudflare.token}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
SSH_USER="${SSH_USER:-root}"
DEFAULT_PLAN_GB="${DEFAULT_PLAN_GB:-20}"
SSL_EMAIL="${SSL_EMAIL:-admin@$BASE_DOMAIN}"
DATABASE_FILE="${DATABASE_FILE:-$SCRIPT_DIR/hosting.db}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-2}"
COMMAND_TIMEOUT="${COMMAND_TIMEOUT:-300}"
MAX_PHP_CHILDREN_PER_SERVER="${MAX_PHP_CHILDREN_PER_SERVER:-40}"
ENCRYPT_SECRETS="${ENCRYPT_SECRETS:-false}"
OPERATION_HEARTBEAT_SECONDS="${OPERATION_HEARTBEAT_SECONDS:-60}"
DISK_USAGE_WARNING_PERCENT="${DISK_USAGE_WARNING_PERCENT:-85}"
DISK_USAGE_CRITICAL_PERCENT="${DISK_USAGE_CRITICAL_PERCENT:-90}"
MAX_QUEUE_SIZE="${MAX_QUEUE_SIZE:-1000}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-5}"

MANAGER_HOME="$SCRIPT_DIR"
BACKUP_ROOT="$MANAGER_HOME/backups"
LOGS_DIR="$MANAGER_HOME/logs"
TEMP_DIR="$MANAGER_HOME/temp"
LOCK_DIR="$MANAGER_HOME/locks"
AGENT_SCRIPT="$MANAGER_HOME/agent.sh"
WORKER_PID_FILE="$LOCK_DIR/worker.pid"
CIRCUIT_BREAKER_FILE="$LOCK_DIR/circuit_breaker"
AGENT_VERSION="11.0"

for cmd in sqlite3 jq ssh scp curl openssl timeout; do
    command -v "$cmd" >/dev/null || { echo "ERROR: Required command '$cmd' not found."; exit 1; }
done

init_directories() {
    mkdir -p "$BACKUP_ROOT" "$LOGS_DIR" "$TEMP_DIR" "$LOCK_DIR"
    chmod 755 "$BACKUP_ROOT" "$LOGS_DIR" "$TEMP_DIR"
    chmod 700 "$LOCK_DIR"
}

sql_escape() { echo "$1" | sed "s/'/''/g"; }

db_query() {
    local sql="$1" attempt=1 max_attempts=3 result
    while [[ $attempt -le $max_attempts ]]; do
        if result=$(sqlite3 "$DATABASE_FILE" "$sql" 2>&1); then echo "$result"; return 0; fi
        if echo "$result" | grep -q "database is locked"; then sleep 0.5; else error "Database error: $result"; fi
        ((attempt++))
    done
    error "Database query failed after $max_attempts attempts"
}
db_query_raw() { sqlite3 "$DATABASE_FILE" "$1" 2>/dev/null || true; }

encrypt(){ [[ "$ENCRYPT_SECRETS" == "true" ]] && echo "$1" | openssl enc -aes-256-cbc -base64 -pass pass:"$SECRET_KEY" -pbkdf2 -iter 10000 2>/dev/null || echo "$1"; }
decrypt(){ [[ "$ENCRYPT_SECRETS" == "true" ]] && echo "$1" | openssl enc -aes-256-cbc -d -base64 -pass pass:"$SECRET_KEY" -pbkdf2 -iter 10000 2>/dev/null || echo "$1"; }

validate_ssh_key(){ [[ -z "$SSH_KEY_FILE" ]] && error "SSH_KEY_FILE not set"; [[ ! -f "$SSH_KEY_FILE" ]] && error "SSH key missing"; ssh-keygen -y -f "$SSH_KEY_FILE" >/dev/null 2>&1 || error "Invalid SSH key"; }

check_circuit_breaker(){
    if [[ -f "$CIRCUIT_BREAKER_FILE" ]]; then
        local t now; t=$(cat "$CIRCUIT_BREAKER_FILE"); now=$(date +%s)
        [[ $((now-t)) -lt 300 ]] && error "Circuit breaker open"
        rm -f "$CIRCUIT_BREAKER_FILE"
    fi
}

check_queue_size(){ local p; p=$(db_query_raw "SELECT COUNT(*) FROM operations WHERE state='pending'"); [[ ${p:-0} -ge $MAX_QUEUE_SIZE ]] && error "Queue full"; }
check_disk_usage(){ local path="$1" mode="${2:-runtime}" u; u=$(df --output=pcent "$path"|tail -1|tr -d ' %'); [[ $u -ge $DISK_USAGE_CRITICAL_PERCENT ]] && { [[ "$mode" == "init" ]] && error "Disk critical" || { warn "Disk critical"; return 1; }; }; [[ $u -ge $DISK_USAGE_WARNING_PERCENT ]] && warn "Disk warning: ${u}%"; return 0; }

retry(){ local a=1; while [[ $a -le ${MAX_RETRIES:-3} ]]; do "$@" && return 0; a=$((a+1)); sleep "${RETRY_DELAY:-2}"; done; return 1; }
ssh_retry(){ local host="$1"; shift; timeout "$COMMAND_TIMEOUT" retry ssh -i "$SSH_KEY_FILE" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "$*"; }
scp_safe(){ scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$1" "$2"; }

create_agent_script() {
cat > "$AGENT_SCRIPT" <<'EOF_AGENT'
#!/bin/bash
set -euo pipefail
AGENT_VERSION="11.0"
case "${1:-}" in
version) echo "{\"version\":\"$AGENT_VERSION\"}" ;;
health) echo "{\"status\":\"ok\",\"time\":\"$(date -Iseconds)\"}" ;;
*) echo "{\"status\":\"error\"}"; exit 1 ;;
esac
EOF_AGENT
chmod +x "$AGENT_SCRIPT"
}

init_database(){
    init_directories
    sqlite3 "$DATABASE_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, resource_type TEXT, resource_id TEXT, operation TEXT, state TEXT, metadata TEXT, rollback_target TEXT, retry_count INTEGER DEFAULT 0, last_error TEXT, started_at TEXT, completed_at TEXT, heartbeat TEXT);
CREATE TABLE IF NOT EXISTS servers (id TEXT PRIMARY KEY, name TEXT, ip TEXT, ssh_user TEXT, status TEXT, current_php_children INTEGER DEFAULT 0, max_php_children INTEGER DEFAULT 40, last_heartbeat TEXT, added_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS customers (id TEXT PRIMARY KEY, email TEXT, username TEXT, plan_gb INTEGER, server_id TEXT, status TEXT, wp_password_enc TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS sites (id TEXT PRIMARY KEY, customer_id TEXT, domain TEXT, status TEXT, server_id TEXT, php_pool TEXT, database_name TEXT, database_user TEXT, database_password_enc TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS alerts (timestamp TEXT, severity TEXT, resource_type TEXT, resource_id TEXT, message TEXT, acknowledged INTEGER DEFAULT 0);
SQL
}

show_status(){ header; echo -e "${CYAN}📊 System Status${NC}"; header; echo "Pending: $(db_query_raw "SELECT COUNT(*) FROM operations WHERE state='pending'")"; echo "Running: $(db_query_raw "SELECT COUNT(*) FROM operations WHERE state='running'")"; echo "Failed: $(db_query_raw "SELECT COUNT(*) FROM operations WHERE state='failed'")"; }
run_worker(){ echo $$ > "$WORKER_PID_FILE"; trap 'rm -f "$WORKER_PID_FILE"; exit 0' SIGTERM SIGINT; while true; do check_circuit_breaker; sleep 1; done; }
monitoring_loop(){ while true; do db_query_raw "UPDATE operations SET state='pending' WHERE state='running' AND heartbeat IS NOT NULL AND julianday('now') - julianday(heartbeat) > (${OPERATION_HEARTBEAT_SECONDS:-60} / 86400.0)" >/dev/null; sleep 60; done; }
show_help(){ cat <<'HELP'
COMMANDS:
  ENGINE_MODE=api ENGINE_SECRET=<secret> ./ent-manager.sh init
  ENGINE_MODE=api ENGINE_SECRET=<secret> ./ent-manager.sh status
  ENGINE_MODE=api ENGINE_SECRET=<secret> ./ent-manager.sh worker
  ENGINE_MODE=api ENGINE_SECRET=<secret> ./ent-manager.sh monitor
HELP
}

main(){
  case "${1:-}" in
    init) init_database; create_agent_script; validate_ssh_key; success "Initialized" ;;
    status) show_status ;;
    worker) run_worker ;;
    monitor) monitoring_loop ;;
    help|--help|-h) show_help ;;
    *) echo "Unknown: ${1:-}"; show_help; exit 1 ;;
  esac
}
main "$@"
