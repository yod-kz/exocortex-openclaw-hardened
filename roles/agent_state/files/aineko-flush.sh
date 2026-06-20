#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  aineko-flush.sh [--purpose TEXT] [--message TEXT] [--file PATH]

Append durable memory notes to the canonical daily log:
  memory/YYYY-MM-DD.md

Input may come from --message, --file, stdin, or a combination. The helper
creates today's daily log if absent and appends a timestamped section. It never
rewrites MEMORY.md or bootstrap files.
EOF
}

purpose="memory flush"
message=""
input_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purpose)
      purpose="${2:-}"
      shift 2
      ;;
    --message)
      message="${2:-}"
      shift 2
      ;;
    --file)
      input_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
workspace_dir="$(cd "$script_dir/.." && pwd -P)"
state_dir="$(cd "$workspace_dir/.." && pwd -P)"
memory_dir="$state_dir/memory"
today="$(date +%F)"
daily_log="$memory_dir/$today.md"
scratch="$(mktemp)"
trap 'rm -f "$scratch"' EXIT

if [ -n "$input_path" ]; then
  [ -f "$input_path" ] || {
    echo "Input file does not exist: $input_path" >&2
    exit 2
  }
  cat "$input_path" >> "$scratch"
  printf '\n' >> "$scratch"
fi

if [ -n "$message" ]; then
  printf '%s\n' "$message" >> "$scratch"
fi

if [ ! -t 0 ]; then
  cat >> "$scratch"
fi

if ! grep -q '[^[:space:]]' "$scratch"; then
  echo "No memory content supplied." >&2
  usage >&2
  exit 2
fi

umask 027
mkdir -p "$memory_dir"

append_block() {
  if [ ! -e "$daily_log" ]; then
    printf '# %s\n\n' "$today" >> "$daily_log"
  fi

  {
    printf '\n## %s - %s\n\n' "$(date +%H:%M:%S%z)" "$purpose"
    cat "$scratch"
    printf '\n'
  } >> "$daily_log"
}

if command -v flock >/dev/null 2>&1; then
  lock_path="$memory_dir/.aineko-flush.lock"
  (
    flock 9
    append_block
  ) 9>> "$lock_path"
else
  append_block
fi

printf '%s\n' "$daily_log"
