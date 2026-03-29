#!/usr/bin/env bash

dev_supervisor_app_name() {
  basename "${APP_ROOT:-$PWD}"
}

dev_supervisor_log_dir() {
  echo "${DEV_SUPERVISOR_LOG_DIR:-log/dev-update}"
}

dev_supervisor_diagnostics_dir() {
  echo "$(dev_supervisor_log_dir)/diagnostics"
}

dev_supervisor_tmux_log() {
  echo "$(dev_supervisor_log_dir)/tmux.log"
}

dev_supervisor_overmind_log() {
  echo "$(dev_supervisor_log_dir)/overmind.log"
}

dev_supervisor_tmux_config() {
  echo "${DEV_SUPERVISOR_TMUX_CONFIG:-config/overmind.tmux.conf}"
}

dev_supervisor_tmux_socket_dir() {
  echo "${DEV_SUPERVISOR_TMUX_SOCKET_DIR:-/tmp/tmux-$(id -u)}"
}

dev_supervisor_prepare_logging() {
  mkdir -p "$(dev_supervisor_log_dir)" "$(dev_supervisor_diagnostics_dir)"
  touch "$(dev_supervisor_tmux_log)" "$(dev_supervisor_overmind_log)"
}

dev_supervisor_run_overmind() {
  env \
    -u BUNDLE_BIN_PATH \
    -u BUNDLE_GEMFILE \
    -u BUNDLER_SETUP \
    -u BUNDLER_VERSION \
    -u RUBYLIB \
    -u RUBYOPT \
    -u RUBYGEMS_GEMDEPS \
    "$@"
}

dev_supervisor_overmind_status_output() {
  dev_supervisor_run_overmind overmind status 2>&1
}

dev_supervisor_overmind_has_dead_processes() {
  local output="$1"
  printf '%s\n' "$output" | awk 'NR > 1 { print $3 }' | grep -qx 'dead'
}

dev_supervisor_log_line() {
  local file="$1"
  shift
  printf '[dev-supervisor] %s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$file"
}

dev_supervisor_append_command() {
  local file="$1"
  local label="$2"
  shift 2

  {
    printf '== %s ==\n' "$label"
    "$@" 2>&1 || true
    printf '\n'
  } >> "$file"
}

dev_supervisor_snapshot_state() {
  dev_supervisor_prepare_logging

  local label="${1:-snapshot}"
  local timestamp
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"

  local file
  file="$(dev_supervisor_diagnostics_dir)/${timestamp}-${label}.log"

  {
    printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf 'cwd=%s\n' "$PWD"
    printf 'app_root=%s\n' "${APP_ROOT:-$PWD}"
    printf 'overmind_socket=%s\n' "${OVERMIND_SOCKET:-.overmind.sock}"
    printf 'tmux_socket_dir=%s\n' "$(dev_supervisor_tmux_socket_dir)"
    printf 'tmux_config=%s\n\n' "$(dev_supervisor_tmux_config)"
  } >> "$file"

  dev_supervisor_append_command "$file" "overmind status" dev_supervisor_run_overmind overmind status
  dev_supervisor_append_command "$file" "tmux sockets" sh -c "ls -la '$(dev_supervisor_tmux_socket_dir)' 2>/dev/null"
  dev_supervisor_append_command "$file" "overmind socket" sh -c "ls -la '${OVERMIND_SOCKET:-.overmind.sock}' 2>/dev/null"
  dev_supervisor_append_command "$file" "tmux sessions" sh -c "for socket in '$(dev_supervisor_tmux_socket_dir)'/overmind-$(dev_supervisor_app_name)-*; do [ -S \"\$socket\" ] || continue; echo \"-- \$socket --\"; tmux -S \"\$socket\" ls 2>&1 || true; done"
  dev_supervisor_append_command "$file" "processes" sh -c "ps -ef | rg 'overmind|tmux|bin/dev|bin/rails server|bin/temporal_worker|yarn build --watch|build:css --watch|esbuild' -S || true"

  dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Wrote diagnostics snapshot to $file"
}

dev_supervisor_cleanup_stale_tmux_sockets() {
  dev_supervisor_prepare_logging

  local socket_dir
  socket_dir="$(dev_supervisor_tmux_socket_dir)"

  [ -d "$socket_dir" ] || return 0

  local socket
  local found=0
  for socket in "$socket_dir"/overmind-"$(dev_supervisor_app_name)"-*; do
    [ -S "$socket" ] || continue
    found=1

    if tmux -S "$socket" ls >> "$(dev_supervisor_tmux_log)" 2>&1; then
      dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Keeping active tmux socket $socket"
      continue
    fi

    dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Removing stale tmux socket $socket"
    rm -f "$socket"
  done

  if [ "$found" -eq 0 ]; then
    dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "No overmind tmux sockets found in $socket_dir"
  fi
}

dev_supervisor_tmux_sockets() {
  local socket_dir
  socket_dir="$(dev_supervisor_tmux_socket_dir)"

  [ -d "$socket_dir" ] || return 0

  local socket
  for socket in "$socket_dir"/overmind-"$(dev_supervisor_app_name)"-*; do
    [ -S "$socket" ] || continue
    printf '%s\n' "$socket"
  done
}

dev_supervisor_tmux_has_dead_panes() {
  local socket
  local output

  while IFS= read -r socket; do
    [ -n "$socket" ] || continue

    if ! tmux -S "$socket" ls >> "$(dev_supervisor_tmux_log)" 2>&1; then
      dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Treating tmux socket $socket as unhealthy because tmux ls failed"
      return 0
    fi

    if ! output="$(tmux -S "$socket" list-panes -a -F '#{pane_dead} #{session_name}:#{window_name}.#{pane_index} #{pane_current_command}' 2>> "$(dev_supervisor_tmux_log)")"; then
      dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Treating tmux socket $socket as unhealthy because list-panes failed"
      return 0
    fi

    if printf '%s\n' "$output" | grep -q '^1 '; then
      dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Detected dead tmux panes on $socket"
      printf '%s\n' "$output" >> "$(dev_supervisor_tmux_log)"
      return 0
    fi
  done < <(dev_supervisor_tmux_sockets)

  return 1
}
