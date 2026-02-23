#!/usr/bin/env bash
# Claude Code status line: shows context usage as a progress bar

input=$(cat)

used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir=$(basename "$cwd")

if [ -n "$used_pct" ]; then
  # Build a 20-char progress bar
  bar_width=20
  filled=$(echo "$used_pct $bar_width" | awk '{printf "%d", ($1 / 100) * $2}')
  empty=$((bar_width - filled))

  bar=""
  for i in $(seq 1 "$filled"); do bar="${bar}#"; done
  for i in $(seq 1 "$empty"); do bar="${bar}-"; done

  # Pick color based on usage
  if [ "$(echo "$used_pct" | awk '{print ($1 >= 90)}')" = "1" ]; then
    color="\033[31m"   # red
  elif [ "$(echo "$used_pct" | awk '{print ($1 >= 70)}')" = "1" ]; then
    color="\033[33m"   # yellow
  else
    color="\033[32m"   # green
  fi
  reset="\033[0m"

  used_int=$(echo "$used_pct" | awk '{printf "%d", $1}')
  printf "${color}[${bar}] ${used_int}%% ctx${reset}  %s  %s" "$model" "$dir"
else
  printf "%s  %s" "$model" "$dir"
fi
