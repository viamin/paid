# shellcheck shell=bash

run_sql() {
  local db="$1"
  shift

  if [[ "${BACKEND:-local}" == "docker" ]]; then
    docker exec -e PGPASSWORD="$COMPOSE_DB_PASSWORD" "$COMPOSE_CONTAINER" \
      psql -U "$COMPOSE_DB_USER" -d "$db" -q --no-align --tuples-only "$@"
  else
    local host_args=()
    [[ -n "${DB_HOST:-}" ]] && host_args=(-h "$DB_HOST")
    PGPASSWORD="${DB_PASSWORD:-}" psql "${host_args[@]}" -U "$DB_USER" -d "$db" -q --no-align --tuples-only "$@"
  fi
}

run_sql_exec() {
  local db="$1"
  shift

  if [[ "${BACKEND:-local}" == "docker" ]]; then
    docker exec -e PGPASSWORD="$COMPOSE_DB_PASSWORD" "$COMPOSE_CONTAINER" \
      psql -U "$COMPOSE_DB_USER" -d "$db" -q "$@"
  else
    local host_args=()
    [[ -n "${DB_HOST:-}" ]] && host_args=(-h "$DB_HOST")
    PGPASSWORD="${DB_PASSWORD:-}" psql "${host_args[@]}" -U "$DB_USER" -d "$db" -q "$@"
  fi
}

db_helpers_log_info() {
  if declare -F info >/dev/null; then
    info "$@"
  else
    echo "$*"
  fi
}

db_helpers_log_warn() {
  if declare -F warn >/dev/null; then
    local message="$*"
    warn "${message^}"
  else
    echo "WARNING: $*" >&2
  fi
}

db_helpers_get_rls_tables() {
  local db="$1"

  run_sql "$db" -c "
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND rowsecurity = true
    ORDER BY tablename
  " 2>/dev/null
}

db_helpers_get_policy_tables() {
  local db="$1"

  run_sql "$db" -c "
    SELECT DISTINCT c.relname
    FROM pg_class c
    JOIN pg_policy p ON p.polrelid = c.oid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
    ORDER BY c.relname
  " 2>/dev/null
}

db_helpers_get_data_tables() {
  local db="$1"

  run_sql "$db" -c "
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename NOT IN ('ar_internal_metadata', 'schema_migrations')
    ORDER BY tablename
  " 2>/dev/null
}

db_helpers_set_var() {
  local var_name="$1"
  local value="$2"

  [[ -z "$var_name" ]] && return 0
  printf -v "$var_name" "%s" "$value"
}

db_helpers_get_var() {
  local var_name="$1"

  [[ -z "$var_name" ]] && return 0
  printf "%s" "${!var_name:-}"
}

run_table_alter_best_effort() {
  local db="$1"
  local tables="$2"
  local sql="$3"
  local action="$4"
  local required="${5:-0}"
  local failures=0

  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    if ! run_sql_exec "$db" -c "ALTER TABLE \"$table\" ${sql};" >/dev/null; then
      db_helpers_log_warn "failed to ${action} on ${table}"
      failures=$((failures + 1))
    fi
  done <<< "$tables"

  if [[ "$failures" -gt 0 ]]; then
    db_helpers_log_warn "${failures} table(s) failed while attempting to ${action}"
    if [[ "$required" == "1" ]]; then
      return 1
    fi
  fi
}

disable_rls() {
  local db="$1"
  local required="${2:-0}"
  local cache_var="${3:-RLS_TABLES}"
  local message="${4:-}"
  local tables

  tables="$(db_helpers_get_rls_tables "$db")" || true
  db_helpers_set_var "$cache_var" "$tables"

  if [[ -z "$tables" ]]; then
    return 0
  fi

  if [[ -n "$message" ]]; then
    local count
    count="$(printf "%s\n" "$tables" | wc -l)"
    db_helpers_log_info "${message//%d/$count}"
  fi

  run_table_alter_best_effort "$db" "$tables" "DISABLE ROW LEVEL SECURITY" "disable RLS" "$required"
}

enable_rls() {
  local db="$1"
  local tables="${2:-}"
  local required="${3:-0}"
  local cache_var="${4:-RLS_TABLES}"
  local message="${5:-}"

  if [[ -z "$tables" ]]; then
    tables="$(db_helpers_get_var "$cache_var")"
  fi

  if [[ -z "$tables" ]]; then
    tables="$(db_helpers_get_policy_tables "$db")" || true
    if [[ -z "$tables" ]]; then
      return 0
    fi
  fi

  if [[ -n "$message" ]]; then
    local count
    count="$(printf "%s\n" "$tables" | wc -l)"
    db_helpers_log_info "${message//%d/$count}"
  fi

  run_table_alter_best_effort "$db" "$tables" "ENABLE ROW LEVEL SECURITY" "enable RLS" "$required"
  run_table_alter_best_effort "$db" "$tables" "FORCE ROW LEVEL SECURITY" "force RLS" "$required"
}

disable_triggers() {
  local db="$1"
  local tables="$2"
  local required="${3:-0}"
  local message="${4:-}"

  [[ -n "$message" ]] && db_helpers_log_info "$message"
  # Local restore/regenerate flows run as the application role in CI and on
  # developer machines. PostgreSQL only allows superusers to toggle system
  # triggers, so target user-defined triggers only; FK/system triggers remain
  # enforced by TRUNCATE CASCADE and pg_restore's dependency ordering.
  run_table_alter_best_effort "$db" "$tables" "DISABLE TRIGGER USER" "disable triggers" "$required"
}

enable_triggers() {
  local db="$1"
  local tables="$2"
  local required="${3:-0}"
  local message="${4:-}"

  [[ -n "$message" ]] && db_helpers_log_info "$message"
  run_table_alter_best_effort "$db" "$tables" "ENABLE TRIGGER USER" "enable triggers" "$required"
}
