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

dev_supervisor_tmux_startup_lock_path() {
  local app_root_hash
  app_root_hash="$(printf '%s' "${APP_ROOT:-$PWD}" | sha256sum | awk '{print $1}')"
  echo "/tmp/overmind-$(id -u)-${app_root_hash}.startup.lock"
}

# @spec RAILS-CONTROL-PLANE-016, RAILS-CONTROL-PLANE-017
dev_supervisor_acquire_tmux_startup_lock() {
  local lock_path
  lock_path="$(dev_supervisor_tmux_startup_lock_path)"

  # Keep this descriptor open until bin/dev exits. Its child Overmind startup
  # is therefore serialized with stale-socket cleanup for this workspace.
  exec {DEV_SUPERVISOR_TMUX_STARTUP_LOCK_FD}>"$lock_path"
  flock -n "$DEV_SUPERVISOR_TMUX_STARTUP_LOCK_FD"
}

dev_supervisor_prepare_logging() {
  mkdir -p "$(dev_supervisor_log_dir)" "$(dev_supervisor_diagnostics_dir)"
  touch "$(dev_supervisor_tmux_log)" "$(dev_supervisor_overmind_log)"
}

dev_supervisor_run_clean() {
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

dev_supervisor_run_overmind() {
  dev_supervisor_run_clean "$@"
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

dev_supervisor_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

dev_supervisor_tty() {
  tty 2>/dev/null || echo "not-a-tty"
}

dev_supervisor_append_shell_context() {
  local file="$1"

  {
    printf '== shell context ==\n'
    printf 'pid=%s\n' "$$"
    printf 'ppid=%s\n' "$PPID"
    printf 'pwd=%s\n' "$PWD"
    printf 'tty=%s\n' "$(dev_supervisor_tty)"
    printf 'term=%s\n' "${TERM:-}"
    printf 'shell=%s\n' "${SHELL:-}"
    printf 'tmux=%s\n' "${TMUX:-}"
    printf 'overmind_socket=%s\n' "${OVERMIND_SOCKET:-}"
    printf '\n'
  } >> "$file"

  dev_supervisor_append_command "$file" "process self" \
    sh -c "ps -o pid=,ppid=,pgid=,sid=,tpgid=,tty=,stat=,etime=,command= -p $$ ${PPID:+-p $PPID} 2>&1"
  # pstree -aps loads the full process table in this container (~1.5s even
  # with a pid argument), which dominates diagnostic runtime. In fast-mode
  # (set by the bin/dev spec suite) skip straight to the cheaper ps -ef path
  # so tests do not accumulate seconds per snapshot.
  if [ "${DEV_SUPERVISOR_FAST_DIAGNOSTICS:-0}" = "1" ]; then
    dev_supervisor_append_command "$file" "process tree" \
      sh -c "ps -ef 2>&1"
  else
    dev_supervisor_append_command "$file" "process tree" \
      sh -c "pstree -aps $$ 2>&1 || ps -ef 2>&1"
  fi
  dev_supervisor_append_command "$file" "selected env" \
    sh -c "env | sort | grep -E '^(TERM|TMUX|OVERMIND_SOCKET|OVERMIND_AUTO_RESTART|GOOD_JOB_DEV_MAX_THREADS|GOOD_JOB_MAX_THREADS|GOOD_JOB_EXECUTION_MODE|PATH|SHELL|STARTUP_CLEANUP_GRACE_PERIOD|SKIP_DEV_CLEANUP)=' 2>&1 || true"
  dev_supervisor_append_command "$file" "tty settings" \
    sh -c "stty -a < /dev/tty 2>&1 || true"
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

dev_supervisor_append_tmux_details() {
  local file="$1"
  local socket
  local panes

  while IFS= read -r socket; do
    [ -n "$socket" ] || continue

    {
      printf '== tmux socket details: %s ==\n' "$socket"
      tmux -S "$socket" display-message -p \
        'session=#{session_name} attached=#{session_attached} windows=#{session_windows} created=#{session_created_string}' 2>&1 || true
      printf '\n'
    } >> "$file"

    panes="$(tmux -S "$socket" list-panes -a -F \
      '#{session_name}|#{window_name}|#{pane_index}|#{pane_id}|#{pane_pid}|#{pane_dead}|#{pane_current_command}|#{pane_start_command}|#{pane_current_path}' 2>&1 || true)"

    {
      printf '== tmux panes: %s ==\n' "$socket"
      printf '%s\n' "$panes"
      printf '\n'
    } >> "$file"

    while IFS='|' read -r session_name window_name pane_index pane_id pane_pid pane_dead pane_current_command _pane_start_command _pane_current_path; do
      [ -n "${pane_id:-}" ] || continue
      [ "${pane_id#%}" != "$pane_id" ] || continue

      {
        printf '== tmux pane capture: %s %s:%s.%s pid=%s dead=%s cmd=%s ==\n' \
          "$socket" "$session_name" "$window_name" "$pane_index" "$pane_pid" "$pane_dead" "$pane_current_command"
        tmux -S "$socket" capture-pane -p -t "$pane_id" -S -200 2>&1 || true
        printf '\n'
      } >> "$file"
    done <<< "$panes"
  done < <(dev_supervisor_tmux_sockets)
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

  dev_supervisor_append_shell_context "$file"
  dev_supervisor_append_command "$file" "overmind status" dev_supervisor_run_overmind overmind status
  dev_supervisor_append_command "$file" "tmux sockets" sh -c "ls -la '$(dev_supervisor_tmux_socket_dir)' 2>/dev/null"
  dev_supervisor_append_command "$file" "overmind socket" sh -c "ls -la '${OVERMIND_SOCKET:-.overmind.sock}' 2>/dev/null"
  dev_supervisor_append_command "$file" "tmux sessions" sh -c "for socket in '$(dev_supervisor_tmux_socket_dir)'/overmind-$(dev_supervisor_app_name)-*; do [ -S \"\$socket\" ] || continue; echo \"-- \$socket --\"; tmux -S \"\$socket\" ls 2>&1 || true; done"
  dev_supervisor_append_tmux_details "$file"
  dev_supervisor_append_command "$file" "processes" sh -c "if command -v rg >/dev/null 2>&1; then ps -ef | rg 'overmind|tmux|bin/dev|bin/rails server|bin/jobs|bin/temporal_worker|yarn build --watch|build:css --watch|esbuild' -S; else ps -ef | grep -E 'overmind|tmux|bin/dev|bin/rails server|bin/jobs|bin/temporal_worker|yarn build --watch|build:css --watch|esbuild' | grep -v grep; fi 2>&1 || true"
  dev_supervisor_append_command "$file" "memory summary" sh -c "free -h 2>&1 || true"
  dev_supervisor_append_command "$file" "top rss processes" sh -c "ps -eo pid=,ppid=,etime=,stat=,rss=,vsz=,command= --sort=-rss | head -30 2>&1 || true"
  dev_supervisor_append_command "$file" "cgroup memory" sh -c "for path in /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events /sys/fs/cgroup/memory.swap.current /sys/fs/cgroup/memory.swap.max; do [ -e \"\$path\" ] || continue; echo \"-- \$path --\"; cat \"\$path\"; done 2>&1 || true"
  dev_supervisor_append_command "$file" "overmind temp files" sh -c "ls -la /tmp/overmind-* 2>/dev/null || true"

  dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Wrote diagnostics snapshot to $file"
}

dev_supervisor_cleanup_stale_tmux_sockets() {
  dev_supervisor_prepare_logging

  local socket_dir
  local sessions
  socket_dir="$(dev_supervisor_tmux_socket_dir)"

  [ -d "$socket_dir" ] || return 0

  local socket
  local found=0
  for socket in "$socket_dir"/overmind-"$(dev_supervisor_app_name)"-*; do
    [ -S "$socket" ] || continue
    found=1

    if ! dev_supervisor_tmux_socket_old_enough "$socket"; then
      continue
    fi

    if sessions="$(tmux -S "$socket" ls 2>> "$(dev_supervisor_tmux_log)")"; then
      if [ -n "$sessions" ]; then
        dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Keeping active tmux socket $socket"
        continue
      fi
      # An empty server is still alive. Stop it before removing its socket.
      if ! tmux -S "$socket" kill-server >> "$(dev_supervisor_tmux_log)" 2>&1; then
        dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Could not stop empty tmux server $socket"
        continue
      fi
      # kill-server removes its own socket; do not unlink a replacement socket.
      continue
    fi

    dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Removing stale tmux socket $socket"
    rm -f "$socket"
  done

  if [ "$found" -eq 0 ]; then
    dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "No overmind tmux sockets found in $socket_dir"
  fi
}

dev_supervisor_tmux_socket_old_enough() {
  local modified_at
  modified_at="$(stat -c %Y "$1" 2>/dev/null)" || return 1
  [ $(( $(date +%s) - modified_at )) -ge 60 ]
}

dev_supervisor_cleanup_stale_overmind_tmp_dirs() {
  dev_supervisor_prepare_logging

  local app
  app="$(dev_supervisor_app_name)"
  local socket_dir
  socket_dir="$(dev_supervisor_tmux_socket_dir)"

  local dir
  local found=0
  for dir in /tmp/overmind-"${app}"-*; do
    [ -d "$dir" ] || continue
    found=1

    local suffix="${dir##*/overmind-"${app}"-}"
    local socket="${socket_dir}/overmind-${app}-${suffix}"
    if [ -S "$socket" ] && tmux -S "$socket" ls >/dev/null 2>&1; then
      dev_supervisor_log_line "$(dev_supervisor_overmind_log)" "Keeping active overmind tmp dir $dir"
      continue
    fi

    dev_supervisor_log_line "$(dev_supervisor_overmind_log)" "Removing stale overmind tmp dir $dir"
    rm -rf "$dir"
  done

  if [ "$found" -eq 0 ]; then
    dev_supervisor_log_line "$(dev_supervisor_overmind_log)" "No overmind tmp dirs found in /tmp"
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
  local sessions
  local failed=0
  local responsive=0

  while IFS= read -r socket; do
    [ -n "$socket" ] || continue

    if ! sessions="$(tmux -S "$socket" ls 2>> "$(dev_supervisor_tmux_log)")"; then
      failed=1
      continue
    fi
    responsive=1
    if [ -z "$sessions" ]; then
      continue
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

  if [ "$failed" -eq 1 ] && [ "$responsive" -eq 0 ]; then
    dev_supervisor_log_line "$(dev_supervisor_tmux_log)" "Treating tmux session as unhealthy because no socket responds"
    return 0
  fi
  return 1
}

dev_supervisor_tmux_has_existing_session() {
  local socket sessions paths path
  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    if sessions="$(tmux -S "$socket" ls 2>> "$(dev_supervisor_tmux_log)")" && [ -n "$sessions" ]; then
      # Sockets are shared across worktrees with the same app name.
      if ! paths="$(tmux -S "$socket" list-panes -a -F '#{pane_current_path}' 2>> "$(dev_supervisor_tmux_log)")"; then
        return 0
      fi
      while IFS= read -r path; do
        if [ "$path" = "$APP_ROOT" ]; then
          return 0
        fi
      done <<< "$paths"
      continue
    fi
  done < <(dev_supervisor_tmux_sockets)
  return 1
}

# Records the exact tmux sessions whose panes belong to this workspace. The
# app-name socket prefix narrows the search to Overmind servers for this app;
# the pane path keeps sibling worktrees on the shared tmux server untouched.
DEV_SUPERVISOR_WORKSPACE_TMUX_IDENTITIES=""

dev_supervisor_workspace_tmux_identities() {
  printf '%s\n' "${DEV_SUPERVISOR_WORKSPACE_TMUX_IDENTITIES:-${1:-}}"
}

dev_supervisor_workspace_tmux_sessions() {
  local socket panes session_name pane_path

  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    if ! panes="$(tmux -S "$socket" list-panes -a -F '#{session_name}|#{pane_current_path}' 2>> "$(dev_supervisor_tmux_log)")"; then
      printf '%s|<uninspectable>\n' "$socket"
      return 1
    fi

    while IFS='|' read -r session_name pane_path; do
      [ "$pane_path" = "$APP_ROOT" ] || continue
      printf '%s|%s\n' "$socket" "$session_name"
    done <<< "$panes"
  done < <(dev_supervisor_tmux_sockets)
}

# @spec RAILS-CONTROL-PLANE-019
dev_supervisor_stop_workspace_tmux_sessions() {
  local identities socket session_name

  if ! identities="$(dev_supervisor_workspace_tmux_sessions)"; then
    DEV_SUPERVISOR_WORKSPACE_TMUX_IDENTITIES="$identities"
    return 1
  fi
  identities="$(printf '%s\n' "$identities" | sed '/^$/d' | sort -u)"
  DEV_SUPERVISOR_WORKSPACE_TMUX_IDENTITIES="$identities"
  [ -n "$identities" ] || return 0

  while IFS='|' read -r socket session_name; do
    dev_supervisor_log_line "$(dev_supervisor_tmux_log)" \
      "Stopping orphaned workspace tmux session socket=$socket session=$session_name"
    if ! tmux -S "$socket" kill-session -t "$session_name" >> "$(dev_supervisor_tmux_log)" 2>&1; then
      return 1
    fi
  done <<< "$identities"

  if identities="$(dev_supervisor_workspace_tmux_sessions)"; then
    identities="$(printf '%s\n' "$identities" | sed '/^$/d' | sort -u)"
    DEV_SUPERVISOR_WORKSPACE_TMUX_IDENTITIES="$identities"
    [ -z "$identities" ]
  else
    DEV_SUPERVISOR_WORKSPACE_TMUX_IDENTITIES="$identities"
    return 1
  fi
}

# @spec RAILS-CONTROL-PLANE-015
dev_supervisor_log_memory_sample() {
  local puma_rss_kb temporal_rss_kb host_available_kb cgroup_current_bytes cgroup_max_bytes cgroup_oom_kills
  read -r puma_rss_kb temporal_rss_kb < <(
    ps -eo comm=,rss=,args= | awk '
      $1 == "ruby" && /puma .*\[paid\]/ { puma += $2 }
      $1 == "ruby" && /ruby bin\/temporal_worker/ { temporal += $2 }
      END { printf "%d %d\n", puma, temporal }
    '
  )
  host_available_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null)"
  cgroup_current_bytes="$(cat /sys/fs/cgroup/memory.current 2>/dev/null)"
  cgroup_max_bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
  cgroup_oom_kills="$(awk '$1 == "oom_kill" { print $2 }' /sys/fs/cgroup/memory.events 2>/dev/null)"
  dev_supervisor_log_line "$(dev_supervisor_overmind_log)" \
    "memory_sample puma_rss_kb=${puma_rss_kb:-0} temporal_rss_kb=${temporal_rss_kb:-0} host_available_kb=${host_available_kb:-unknown} cgroup_current_bytes=${cgroup_current_bytes:-unknown} cgroup_max_bytes=${cgroup_max_bytes:-unknown} cgroup_oom_kills=${cgroup_oom_kills:-unknown}"
}

dev_supervisor_monitor_overmind() {
  local parent_pid="$1"
  local label_prefix="${2:-bin-dev-monitor}"
  local interval="${DEV_SUPERVISOR_MONITOR_INTERVAL:-2}"
  local started=0
  local status_output
  local poll_count=0

  while kill -0 "$parent_pid" >/dev/null 2>&1; do
    if (( poll_count % 5 == 0 )); then
      dev_supervisor_log_memory_sample
    fi
    poll_count=$((poll_count + 1))

    if [ -S "${OVERMIND_SOCKET:-}" ]; then
      started=1
    fi

    if [ "$started" -eq 1 ]; then
      if ! status_output="$(dev_supervisor_overmind_status_output)"; then
        dev_supervisor_log_line "$(dev_supervisor_overmind_log)" \
          "${label_prefix} detected unhealthy overmind status: ${status_output//$'\n'/ | }"
        dev_supervisor_snapshot_state "${label_prefix}-status-failed"
        return 0
      fi

      if dev_supervisor_tmux_has_dead_panes; then
        dev_supervisor_log_line "$(dev_supervisor_overmind_log)" \
          "${label_prefix} detected dead tmux panes"
        dev_supervisor_snapshot_state "${label_prefix}-dead-pane"
        return 0
      fi
    fi

    sleep "$interval"
  done
}
