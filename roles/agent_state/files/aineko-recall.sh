#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  aineko-recall.sh SUBJECT [--for PURPOSE] [--chars MAX]

Concatenates memory/*.md and research/*.md up to MAX characters and asks agy
for a focused recall summary with source paths preserved.
EOF
}

subject=""
purpose="general recall"
max_chars="500000"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --for)
      purpose="${2:-}"
      shift 2
      ;;
    --chars)
      max_chars="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -z "$subject" ]; then
        subject="$1"
      else
        subject="$subject $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$subject" ]; then
  usage >&2
  exit 2
fi

if ! command -v agy >/dev/null 2>&1; then
  echo "agy is required for aineko-recall.sh" >&2
  exit 127
fi

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
workspace_dir="$(cd "$script_dir/.." && pwd -P)"
state_dir="$(cd "$workspace_dir/.." && pwd -P)"
corpus_file="$(mktemp)"
prompt_file="$(mktemp)"
trap 'rm -f "$corpus_file" "$prompt_file"' EXIT

total=0
{
  for dir in "$state_dir/memory" "$state_dir/research" "$workspace_dir/memory" "$workspace_dir/research"; do
    [ -d "$dir" ] || continue
    find "$dir" -type f -name '*.md' -print0
  done
} | sort -z | while IFS= read -r -d '' file; do
  if [ "$total" -ge "$max_chars" ]; then
    break
  fi
  rel="$(realpath --relative-to="$state_dir" "$file" 2>/dev/null || printf '%s' "$file")"
  bytes="$(wc -c < "$file" | tr -d ' ')"
  remaining=$(( max_chars - total ))
  take="$bytes"
  if [ "$take" -gt "$remaining" ]; then
    take="$remaining"
  fi
  printf '\n\n--- %s ---\n' "$rel" >> "$corpus_file"
  head -c "$take" "$file" >> "$corpus_file"
  printf '\n' >> "$corpus_file"
  total=$(( total + take ))
  if [ "$take" -lt "$bytes" ]; then
    break
  fi
done

{
  printf 'You are acting as a brute-force recall assistant.\n'
  printf 'Find relevant facts, decisions, dates, and source paths. Preserve uncertainty and do not invent missing details.\n\n'
  printf 'Subject: %s\n' "$subject"
  printf 'Purpose: %s\n\n' "$purpose"
  printf 'Corpus follows:\n'
  cat "$corpus_file"
} > "$prompt_file"

agy -p "$(cat "$prompt_file")"
