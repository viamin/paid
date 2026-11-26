#!/usr/bin/env bash
# Standalone updater/controller transport. Original coprocess descriptors stay
# CLOEXEC: never duplicate them into descriptors inherited by restarted services.
# @spec DEVELOPMENT-ENVIRONMENT-UPDATE-006

WORKER_ADMISSION_ACTIVE=0
WORKER_ADMISSION_STOPPING=0
WORKER_ADMISSION_COMPLETE=0
WORKER_ADMISSION_ALREADY_COMPLETE=0
WORKER_ADMISSION_CHILD_PID=""
WORKER_ADMISSION_CHILD_IDENTITY=""
WORKER_ADMISSION_READ_FD=""
WORKER_ADMISSION_WRITE_FD=""
WORKER_ADMISSION_COHORT=""
WORKER_ADMISSION_TARGET=""
WORKER_ADMISSION_DEADLINE=""

worker_admission_remaining() {
  python3 -c 'import sys,time; remaining=float(sys.argv[1])-time.monotonic(); assert remaining>0; print(remaining)' "$WORKER_ADMISSION_DEADLINE"
}

worker_admission_discover() {
  local budget="${1:-5}" target="${2:-}" status
  local -a arguments=(--workspace "$APP_ROOT")
  if [ -n "$target" ]; then
    arguments+=(--ready-target "$target" --readiness-directory "${TMPDIR:-/tmp}")
  fi
  status="$(dev_supervisor_run_overmind timeout "$budget" overmind status 2>/dev/null)" || return 1
  printf '%s\n' "$status" | timeout "$budget" python3 "$APP_ROOT/bin/lib/worker_admission_cohort.py" "${arguments[@]}"
}

worker_admission_status() {
  python3 -c 'import json,sys; value=json.loads(sys.argv[1]); assert value.get("status")==sys.argv[2]' "$1" "$2"
}

worker_admission_command() {
  local command="$1" expected="$2" response
  printf '%s\n' "$command" >&"$WORKER_ADMISSION_WRITE_FD" || return 1
  IFS= read -r -t 5 response <&"$WORKER_ADMISSION_READ_FD" || return 1
  if ! worker_admission_status "$response" "$expected"; then
    log "Worker admission did not confirm ${expected}; admission requires explicit recovery."
    return 1
  fi
}

worker_admission_begin() {
  local target="$1" mode="${2:-drain}" budget identities entry both response
  local -a arguments=(--workspace "$APP_ROOT" --target-revision "$target" --mode "$mode" --finish-handshake)
  [ "$WORKER_ADMISSION_ACTIVE" -eq 0 ] || return 0
  WORKER_ADMISSION_TARGET="$target"
  WORKER_ADMISSION_DEADLINE="$(python3 -c 'import time; print(time.monotonic()+120)')" || return 1
  budget="$(worker_admission_remaining)" || return 1
  WORKER_ADMISSION_COHORT="$(worker_admission_discover "$budget")" || return 1
  identities="$(python3 -c 'import json,sys; value=json.loads(sys.argv[1]); print("\n".join(role+"="+str(value[role]["pid"])+":"+str(value[role]["start_ticks"]) for role in ("agent","poll")))' "$WORKER_ADMISSION_COHORT")" || return 1
  while IFS= read -r entry; do
    arguments+=(--process "$entry")
  done <<< "$identities"
  both="$(python3 -c 'import json,sys; value=json.loads(sys.argv[1]); print(int(value["agent"]==value["poll"]))' "$WORKER_ADMISSION_COHORT")" || return 1
  local role path
  for role in agent poll; do
    path="${TMPDIR:-/tmp}/paid-worker-ready-temporal_worker-${role}"
    [ "$both" -eq 0 ] || path="${TMPDIR:-/tmp}/paid-worker-ready-temporal_worker-both"
    arguments+=(--role "${role}=${path}")
  done
  budget="$(worker_admission_remaining)" || return 1
  arguments+=(--timeout "$budget")
  coproc WORKER_ADMISSION { exec python3 "$APP_ROOT/bin/lib/worker_admission.py" "${arguments[@]}"; }
  WORKER_ADMISSION_CHILD_PID="$WORKER_ADMISSION_PID"
  WORKER_ADMISSION_READ_FD="${WORKER_ADMISSION[0]}"
  WORKER_ADMISSION_WRITE_FD="${WORKER_ADMISSION[1]}"
  WORKER_ADMISSION_CHILD_IDENTITY="$(python3 "$APP_ROOT/bin/lib/worker_admission_cohort.py" --workspace "$APP_ROOT" --controller-identity "$WORKER_ADMISSION_CHILD_PID" --caller-pid "$$")" || return 1
  if ! IFS= read -r -t "$budget" response <&"$WORKER_ADMISSION_READ_FD"; then
    log "Worker admission acknowledgement was not observed within the original budget."
    return 1
  fi
  worker_admission_status "$response" acknowledged || return 1
  worker_admission_remaining >/dev/null || return 1
  WORKER_ADMISSION_ALREADY_COMPLETE="$(python3 -c 'import json,sys; print(int(json.loads(sys.argv[1]).get("completed",False)))' "$response")" || return 1
  WORKER_ADMISSION_ACTIVE=1
  log "Both worker roles acknowledged the owned admission generation."
}

worker_admission_checkpoint() {
  local phase="$1"
  worker_admission_command "{\"action\":\"checkpoint\",\"phase\":\"${phase}\"}" checkpoint
}

worker_admission_before_stop() {
  local current
  [ "$WORKER_ADMISSION_ACTIVE" -eq 1 ] || return 0
  if [ "$WORKER_ADMISSION_ALREADY_COMPLETE" -eq 1 ]; then
    log "This admission generation already completed; another stop is not authorized."
    return 1
  fi
  current="$(worker_admission_discover)" || return 1
  if [ "$current" != "$WORKER_ADMISSION_COHORT" ]; then
    log "Supervisor-owned worker cohort changed before stop; deferring."
    return 1
  fi
  worker_admission_checkpoint stopping || return 1
  # A failed stop command may still have stopped a process. From this point,
  # EXIT must preserve the generation instead of assuming pre-stop abort safe.
  WORKER_ADMISSION_STOPPING=1
}

worker_admission_wait_originals() {
  local deadline="$1"
  while python3 -c 'import sys,time; sys.exit(0 if time.monotonic()<float(sys.argv[1]) else 1)' "$deadline"; do
    if printf '%s\n' "$WORKER_ADMISSION_COHORT" | python3 "$APP_ROOT/bin/lib/worker_admission_cohort.py" --workspace "$APP_ROOT" --originals-gone >/dev/null; then
      return 0
    fi
    sleep "${OVERMIND_POLL_INTERVAL:-1}"
  done
  log "Original worker exit was not verified within the existing stop budget; admission remains closed."
  return 1
}

worker_admission_resume() {
  local target="$1" current="" i
  [ "$WORKER_ADMISSION_ACTIVE" -eq 1 ] || return 0
  [ "$target" = "$WORKER_ADMISSION_TARGET" ] || return 1
  for ((i = 0; i < ${WORKER_ADOPTION_POLL_COUNT:-120}; i += 1)); do
    if current="$(worker_admission_discover 5 "$target")"; then
      break
    fi
    sleep "${OVERMIND_POLL_INTERVAL:-1}"
  done
  [ -n "$current" ] || return 1
  worker_admission_command "{\"action\":\"resume\",\"processes\":${current}}" resumed || return 1
  WORKER_ADMISSION_COMPLETE=1
  printf 'close\n' >&"$WORKER_ADMISSION_WRITE_FD" || true
  worker_admission_cleanup
  log "Target worker boots verified and owned admission generation resumed."
}

worker_admission_cleanup() {
  local result=$?
  if [ -z "$WORKER_ADMISSION_CHILD_PID" ]; then
    return "$result"
  fi
  if [ "$WORKER_ADMISSION_ACTIVE" -eq 1 ] && [ "$WORKER_ADMISSION_STOPPING" -eq 0 ] && [ "$WORKER_ADMISSION_COMPLETE" -eq 0 ]; then
    worker_admission_command abort aborted || true
    printf 'close\n' >&"$WORKER_ADMISSION_WRITE_FD" || true
  fi
  if [ -n "$WORKER_ADMISSION_WRITE_FD" ]; then
    exec {WORKER_ADMISSION_WRITE_FD}>&- || true
    WORKER_ADMISSION_WRITE_FD=""
  fi
  if [ -n "$WORKER_ADMISSION_READ_FD" ]; then
    exec {WORKER_ADMISSION_READ_FD}<&- || true
    WORKER_ADMISSION_READ_FD=""
  fi
  local reaped
  if [ -n "$WORKER_ADMISSION_CHILD_IDENTITY" ] && reaped="$(python3 "$APP_ROOT/bin/lib/worker_admission_cohort.py" --workspace "$APP_ROOT" --reap-controller "$WORKER_ADMISSION_CHILD_IDENTITY")"; then
    if python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("wait_safe") else 1)' "$reaped"; then
      wait "$WORKER_ADMISSION_CHILD_PID" 2>/dev/null || true
    fi
  else
    log "Controller identity or exit is unknown; no numeric-PID signal was sent. Admission requires recovery."
  fi
  WORKER_ADMISSION_CHILD_PID=""
  WORKER_ADMISSION_CHILD_IDENTITY=""
  WORKER_ADMISSION_ACTIVE=0
  if [ "$WORKER_ADMISSION_STOPPING" -eq 1 ] && [ "$WORKER_ADMISSION_COMPLETE" -eq 0 ]; then
    log "Worker admission remains closed; recover this workspace and pinned target with bin/dev-update --recover."
  fi
  return "$result"
}
