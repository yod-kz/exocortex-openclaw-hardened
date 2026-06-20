#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run_graph_memory.sh [--workspace PATH] [--sessions-dir PATH] [--include-sessions] [--skip-pykeen]
                      [--extractor heuristic|agy|auto] [--force]

Build graph memory artifacts under workspace/memory/graph and generate
structural recall rows for native associative recall. PyKEEN is used when
available; otherwise pykeen_structural.py writes deterministic fallback
structural embeddings.
EOF
}

workspace=""
include_sessions=false
skip_pykeen=false
force=false
extractor="heuristic"
agy_timeout="20"
agy_max_chunks="0"
structural_recall_limit="200"
pykeen_dim="64"
pykeen_epochs="20"
pykeen_similar_limit="200"
pykeen_prediction_limit="200"
pykeen_recall_limit="120"
session_dirs=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --include-sessions)
      include_sessions=true
      shift
      ;;
    --sessions-dir)
      session_dirs+=("${2:-}")
      shift 2
      ;;
    --skip-pykeen)
      skip_pykeen=true
      shift
      ;;
    --extractor)
      extractor="${2:-}"
      shift 2
      ;;
    --agy-timeout)
      agy_timeout="${2:-}"
      shift 2
      ;;
    --agy-max-chunks)
      agy_max_chunks="${2:-}"
      shift 2
      ;;
    --structural-recall-limit)
      structural_recall_limit="${2:-}"
      shift 2
      ;;
    --pykeen-dim)
      pykeen_dim="${2:-}"
      shift 2
      ;;
    --pykeen-epochs)
      pykeen_epochs="${2:-}"
      shift 2
      ;;
    --pykeen-similar-limit)
      pykeen_similar_limit="${2:-}"
      shift 2
      ;;
    --pykeen-prediction-limit)
      pykeen_prediction_limit="${2:-}"
      shift 2
      ;;
    --pykeen-recall-limit)
      pykeen_recall_limit="${2:-}"
      shift 2
      ;;
    --force)
      force=true
      shift
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
if [ -z "$workspace" ]; then
  workspace="$(cd "$script_dir/../.." && pwd -P)"
else
  workspace="$(cd "$workspace" && pwd -P)"
fi

pipeline_args=(
  --workspace "$workspace"
  --extractor "$extractor"
  --agy-timeout "$agy_timeout"
  --agy-max-chunks "$agy_max_chunks"
  --structural-recall-limit "$structural_recall_limit"
)
if [ "$include_sessions" = true ]; then
  pipeline_args+=(--include-sessions)
fi
if [ "$force" = true ]; then
  pipeline_args+=(--force)
fi
for session_dir in "${session_dirs[@]}"; do
  pipeline_args+=(--sessions-dir "$session_dir")
done

python3 "$script_dir/graph_memory_pipeline.py" "${pipeline_args[@]}"

if [ "$skip_pykeen" = false ]; then
  python3 "$script_dir/pykeen_structural.py" \
    --workspace "$workspace" \
    --dim "$pykeen_dim" \
    --epochs "$pykeen_epochs" \
    --similar-limit "$pykeen_similar_limit" \
    --prediction-limit "$pykeen_prediction_limit" \
    --recall-limit "$pykeen_recall_limit"
fi

python3 "$script_dir/graph_query.py" --workspace "$workspace" --stats
