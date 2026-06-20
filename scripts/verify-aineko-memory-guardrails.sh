#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  verify-aineko-memory-guardrails.sh --workspace PATH [options]

Options:
  --workspace PATH          Main/private workspace to check
  --public-workspace PATH   Public workspace to scan for canary leaks (repeatable)
  --canary TEXT             Canary fact that must not appear in public workspaces
  --write-manifest PATH     Write protected-file hash/size manifest
  --check-manifest PATH     Verify protected-file hash/size manifest
  --chat-log PATH           Chat transcript/log to scan for internal process chatter (repeatable)

The manifest protects AGENTS.md, SOUL.md, IDENTITY.md, USER.md, and TOOLS.md
from automated rewrite, and records MEMORY.md size so an automated pass cannot
shrink hot memory.
EOF
}

workspace=""
canary=""
write_manifest=""
check_manifest=""
public_workspaces=()
chat_logs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --public-workspace)
      public_workspaces+=("${2:-}")
      shift 2
      ;;
    --canary)
      canary="${2:-}"
      shift 2
      ;;
    --write-manifest)
      write_manifest="${2:-}"
      shift 2
      ;;
    --check-manifest)
      check_manifest="${2:-}"
      shift 2
      ;;
    --chat-log)
      chat_logs+=("${2:-}")
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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

note() {
  echo "OK: $*"
}

[[ -n "$workspace" ]] || fail "--workspace is required"
[[ -d "$workspace" ]] || fail "workspace does not exist: $workspace"
workspace="$(cd "$workspace" && pwd -P)"

protected_files=(AGENTS.md SOUL.md IDENTITY.md USER.md TOOLS.md)

memory_size() {
  local file="$workspace/MEMORY.md"
  if [[ -f "$file" ]]; then
    wc -c < "$file" | tr -d ' '
  else
    echo "-1"
  fi
}

check_no_legacy_queue() {
  local queue
  for queue in "$workspace/.memory-queue" "$(dirname "$workspace")/.memory-queue"; do
    [[ ! -e "$queue" ]] || fail "legacy memory sidecar queue is still present: $queue"
  done
  note "legacy .memory-queue absent"
}

check_hot_memory_has_no_auto_promotions() {
  local file="$workspace/MEMORY.md"
  if [[ -f "$file" ]] && grep -q 'openclaw-memory-promotion:' "$file"; then
    fail "hot MEMORY.md contains automated promotion markers; use memory/promoted.md for machine output"
  fi
  note "hot MEMORY.md has no automated promotion markers"
}

write_manifest_file() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  {
    echo "workspace $workspace"
    for rel in "${protected_files[@]}"; do
      if [[ -f "$workspace/$rel" ]]; then
        sha256sum "$workspace/$rel" | awk -v rel="$rel" '{ print "sha256 " $1 " " rel }'
      else
        echo "missing $rel"
      fi
    done
    echo "memory_size $(memory_size)"
  } > "$out"
  note "wrote manifest $out"
}

check_manifest_file() {
  local manifest="$1"
  [[ -f "$manifest" ]] || fail "manifest does not exist: $manifest"
  local kind arg1 arg2 expected actual current
  while read -r kind arg1 arg2; do
    case "$kind" in
      workspace)
        ;;
      sha256)
        expected="$arg1"
        [[ -f "$workspace/$arg2" ]] || fail "protected file missing after run: $arg2"
        actual="$(sha256sum "$workspace/$arg2" | awk '{ print $1 }')"
        [[ "$actual" == "$expected" ]] || fail "protected file changed: $arg2"
        ;;
      missing)
        [[ ! -e "$workspace/$arg1" ]] || fail "previously missing protected file now exists: $arg1"
        ;;
      memory_size)
        expected="$arg1"
        current="$(memory_size)"
        if [[ "$expected" -ge 0 && "$current" -ge 0 && "$current" -lt "$expected" ]]; then
          fail "MEMORY.md shrank from $expected bytes to $current bytes"
        fi
        ;;
    esac
  done < "$manifest"
  note "manifest invariants hold"
}

check_canary_leak() {
  [[ -n "$canary" ]] || return 0
  local public
  for public in "${public_workspaces[@]}"; do
    [[ -d "$public" ]] || fail "public workspace does not exist: $public"
    if grep -R -F --exclude-dir=.git -- "$canary" "$public" >/dev/null 2>&1; then
      fail "private canary leaked into public workspace: $public"
    fi
  done
  note "private canary absent from public workspaces"
}

check_internal_process_chatter() {
  local log
  for log in "${chat_logs[@]}"; do
    [[ -f "$log" ]] || fail "chat log does not exist: $log"
    if grep -E '(^|[[:space:]])(active-memory:|memory-core:|dreaming verbose|short-term promotion|creating the file fresh)' "$log" >/dev/null; then
      fail "internal memory/process chatter appears in chat log: $log"
    fi
  done
  [[ "${#chat_logs[@]}" -eq 0 ]] || note "chat logs do not contain internal memory chatter"
}

check_no_legacy_queue
check_hot_memory_has_no_auto_promotions
[[ -z "$write_manifest" ]] || write_manifest_file "$write_manifest"
[[ -z "$check_manifest" ]] || check_manifest_file "$check_manifest"
check_canary_leak
check_internal_process_chatter

note "Aineko memory guardrails passed"
