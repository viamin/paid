#!/usr/bin/env bash
set -uo pipefail

mode="${1:-incremental}"
target_ref="${2:-}"
output_file="${MUTANT_OUTPUT_FILE:-tmp/mutant-viamin.log}"

mkdir -p "$(dirname "$output_file")"

declare -a failures=()

extract_note() {
  local file="$1"

  grep -Eim1 'wrong constant name run|unknown|unrecognized|invalid option|no such command|unknown switch' "$file" || true
}

run_probe() {
  local label="$1"
  shift

  local probe_file
  probe_file="$(mktemp)"

  set +e
  "$@" >"$probe_file" 2>&1
  local status=$?
  set -e

  local note="ok"
  if (( status != 0 )); then
    note="$(extract_note "$probe_file")"
    note="${note:-command exited non-zero}"
    failures+=("- \`${label}\` exited ${status}: ${note}")
  fi

  {
    echo "- \`${label}\`: exit ${status}"
    if [[ -n "$note" && "$note" != "ok" ]]; then
      echo "  ${note}"
    fi
  } >> "${output_file}.probes"

  rm -f "$probe_file"
}

main_command=(bundle exec mutant run)
if [[ "$mode" == "incremental" && -n "$target_ref" ]]; then
  main_command+=(--since "$target_ref")
fi

: > "${output_file}.probes"
run_probe "mutant run --help" bundle exec mutant run --help
if [[ "$mode" == "incremental" && -n "$target_ref" ]]; then
  run_probe "mutant run --since ${target_ref} --help" bundle exec mutant run --since "$target_ref" --help
fi

set +e
"${main_command[@]}" 2>&1 | tee "$output_file"
status=${PIPESTATUS[0]}
set -e

if (( status != 0 )); then
  main_note="$(extract_note "$output_file")"
  if [[ -n "$main_note" ]]; then
    failures+=("- \`$(printf '%q ' "${main_command[@]}" | sed 's/ $//')\` exited ${status}: ${main_note}")
  else
    failures+=("- \`$(printf '%q ' "${main_command[@]}" | sed 's/ $//')\` exited ${status}")
  fi
fi

{
  echo "## viamin/mutant parity (${mode})"
  echo
  echo "- Bundle source: \`viamin/mutant@main\`"
  if [[ -n "$target_ref" ]]; then
    echo "- Target ref: \`${target_ref}\`"
  fi
  echo "- Command: \`$(printf '%q ' "${main_command[@]}" | sed 's/ $//')\`"
  echo
  echo "### CLI probe results"
  cat "${output_file}.probes"
  echo
  echo "### Failing flags / commands"
  if ((${#failures[@]} == 0)); then
    echo "- None"
  else
    printf '%s\n' "${failures[@]}"
  fi
  echo
  echo "### Command tail"
  echo
  echo '```text'
  tail -n 200 "$output_file"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

exit "$status"
