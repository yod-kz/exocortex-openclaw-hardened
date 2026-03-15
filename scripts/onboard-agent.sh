#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# onboard-agent.sh — Onboard a new OpenClaw agent
#
# Creates Slack app (via Manifest API), guides Telegram BotFather
# setup, writes vault entries, and appends agent to site config.
#
# Usage:
#   ./scripts/onboard-agent.sh --id atlas --name "Atlas"
#   ./scripts/onboard-agent.sh --id atlas --name "Atlas" --skip-slack
#   ./scripts/onboard-agent.sh --id atlas --name "Atlas" --skip-telegram
#   ./scripts/onboard-agent.sh --id atlas --name "Atlas" --dry-run
#
# Prerequisites:
#   - jq, yq (pip install yq), ansible-vault
#   - For Slack: a config token (see docs/site-config-schema.md)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────
AGENT_ID=""
AGENT_NAME=""
SKIP_SLACK=false
SKIP_TELEGRAM=false
DRY_RUN=false
MAKE_DEFAULT=false
MEMORY_SEARCH=true
STATE_REPO=""
STATE_PATH=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_TPL="${SCRIPT_DIR}/slack-manifest.json.tpl"

# Site config — auto-detect or set via env
SITE_DIR="${OPENCLAW_SITE_DIR:-}"
VAULT_FILE=""
MAIN_FILE=""

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}▸${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}✅${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠️${NC}  %s\n" "$*"; }
err()   { printf "${RED}❌${NC} %s\n" "$*" >&2; }
header() { printf "\n${BOLD}── %s ──────────────────────────────────────${NC}\n" "$*"; }

# ── Usage ───────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --id ID              Agent identifier (lowercase, no spaces)
  --name NAME          Display name (e.g. "Atlas")

Optional:
  --skip-slack         Skip Slack app setup
  --skip-telegram      Skip Telegram bot setup
  --default            Mark as default agent
  --no-memory-search   Disable memory search for this agent
  --state-repo URL     Git repo for agent state
  --state-path PATH    Path within state repo (default: agents/<id>)
  --site-dir DIR       Path to site config repo (default: auto-detect)
  --dry-run            Show what would be done without making changes

Environment:
  OPENCLAW_SITE_DIR    Path to site config repo
  SLACK_CONFIG_TOKEN   Slack app configuration token (for manifest API)
EOF
  exit 1
}

# ── Argument parsing ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)             AGENT_ID="$2"; shift 2 ;;
    --name)           AGENT_NAME="$2"; shift 2 ;;
    --skip-slack)     SKIP_SLACK=true; shift ;;
    --skip-telegram)  SKIP_TELEGRAM=true; shift ;;
    --default)        MAKE_DEFAULT=true; shift ;;
    --no-memory-search) MEMORY_SEARCH=false; shift ;;
    --state-repo)     STATE_REPO="$2"; shift 2 ;;
    --state-path)     STATE_PATH="$2"; shift 2 ;;
    --site-dir)       SITE_DIR="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        usage ;;
    *)                err "Unknown option: $1"; usage ;;
  esac
done

[[ -z "${AGENT_ID}" ]] && { err "--id is required"; usage; }
[[ -z "${AGENT_NAME}" ]] && { err "--name is required"; usage; }

# Validate agent ID format
if [[ ! "${AGENT_ID}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  err "Agent ID must be lowercase alphanumeric (start with letter): ${AGENT_ID}"
  exit 1
fi

# ── Locate site config ─────────────────────────────────────────
find_site_dir() {
  if [[ -n "${SITE_DIR}" ]]; then
    return
  fi
  # Check common sibling directory patterns
  local parent
  parent="$(dirname "${REPO_ROOT}")"
  for candidate in \
    "${parent}/openclaw-hardened-site" \
    "${parent}/site" \
    "${REPO_ROOT}/site"; do
    if [[ -f "${candidate}/inventory/group_vars/agent_hosts/main.yml" ]]; then
      SITE_DIR="${candidate}"
      return
    fi
  done
  err "Cannot find site config directory."
  err "Set OPENCLAW_SITE_DIR or pass --site-dir."
  exit 1
}

find_site_dir
VAULT_FILE="${SITE_DIR}/inventory/group_vars/agent_hosts/vault.yml"
MAIN_FILE="${SITE_DIR}/inventory/group_vars/agent_hosts/main.yml"

info "Site config: ${SITE_DIR}"
info "Vault file:  ${VAULT_FILE}"
info "Main config: ${MAIN_FILE}"

# ── Prerequisite checks ────────────────────────────────────────
check_prerequisites() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v ansible-vault >/dev/null 2>&1 || missing+=("ansible-vault")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    exit 1
  fi

  if [[ ! -f "${MAIN_FILE}" ]]; then
    err "Main config not found: ${MAIN_FILE}"
    exit 1
  fi

  if [[ ! -f "${VAULT_FILE}" ]]; then
    err "Vault file not found: ${VAULT_FILE}"
    exit 1
  fi
}

check_prerequisites

# ── Check if agent already exists ────────────────────────────────
AGENT_EXISTS=false
if grep -q "id: \"${AGENT_ID}\"" "${MAIN_FILE}" 2>/dev/null; then
  AGENT_EXISTS=true
  info "Agent '${AGENT_ID}' already in ${MAIN_FILE} — will add tokens only"
fi

# ── Vault helper ────────────────────────────────────────────────
# Prints entries to add and instructions for ansible-vault edit.
vault_add_entries() {
  local -a entries=("$@")  # key=value pairs

  if ${DRY_RUN}; then
    info "[dry-run] Would need to add to vault:"
    for entry in "${entries[@]}"; do
      info "  ${entry%%=*}: ****"
    done
    return
  fi

  echo ""
  info "Add the following to your vault:"
  printf "  ${CYAN}ansible-vault edit ${VAULT_FILE}${NC}\n"
  echo ""
  for entry in "${entries[@]}"; do
    local key="${entry%%=*}"
    local value="${entry#*=}"
    printf "  ${BOLD}%s${NC}: \"%s\"\n" "${key}" "${value}"
  done
  echo ""
}

# ── Slack setup ─────────────────────────────────────────────────
SLACK_BOT_TOKEN=""
SLACK_APP_TOKEN=""
SLACK_APP_ID=""

setup_slack() {
  header "Slack"

  local config_token="${SLACK_CONFIG_TOKEN:-}"

  # Try to create app via Manifest API
  if [[ -n "${config_token}" ]]; then
    info "Creating Slack app via Manifest API..."

    local manifest
    manifest="$(sed \
      -e "s/__AGENT_FULL_NAME__/${AGENT_NAME}/g" \
      -e "s/__AGENT_DISPLAY_NAME__/${AGENT_NAME%% *}/g" \
      "${MANIFEST_TPL}")"

    if ${DRY_RUN}; then
      info "[dry-run] Would create Slack app with manifest:"
      echo "${manifest}" | jq .
    else
      local response
      response="$(curl -s -X POST "https://slack.com/api/apps.manifest.create" \
        -H "Authorization: Bearer ${config_token}" \
        -H "Content-Type: application/json" \
        -d "{\"manifest\": ${manifest}}")"

      local api_ok
      api_ok="$(echo "${response}" | jq -r '.ok')"

      if [[ "${api_ok}" == "true" ]]; then
        SLACK_APP_ID="$(echo "${response}" | jq -r '.app_id')"
        ok "Slack app created: ${SLACK_APP_ID}"
        echo ""
        warn "Manual steps required to complete Slack setup:"
        echo ""
        printf "  ${BOLD}1.${NC} Install app to workspace:\n"
        printf "     ${CYAN}https://api.slack.com/apps/${SLACK_APP_ID}/oauth${NC}\n"
        printf "     → Click \"Install to Workspace\" → Authorize\n"
        printf "     → Copy the ${BOLD}Bot User OAuth Token${NC} (xoxb-...)\n"
        echo ""
        printf "  ${BOLD}2.${NC} Generate app-level token:\n"
        printf "     ${CYAN}https://api.slack.com/apps/${SLACK_APP_ID}/general${NC}\n"
        printf "     → \"App-Level Tokens\" → Generate\n"
        printf "     → Name: \"socket\" → Scope: ${BOLD}connections:write${NC}\n"
        printf "     → Copy the token (xapp-...)\n"
        echo ""
      else
        local api_error
        api_error="$(echo "${response}" | jq -r '.error // "unknown"')"
        warn "Manifest API failed: ${api_error}"
        warn "Falling back to manual Slack app creation."
        echo ""
        printf "  ${BOLD}Create the app manually:${NC}\n"
        printf "  ${CYAN}https://api.slack.com/apps?new_app=1&manifest_json=$(printf '%s' "${manifest}" | jq -sRr @uri)${NC}\n"
        echo ""
      fi
    fi
  else
    info "No SLACK_CONFIG_TOKEN set — manual Slack app creation required."
    echo ""
    printf "  ${BOLD}Option A:${NC} Create via manifest (recommended):\n"
    printf "    1. Go to ${CYAN}https://api.slack.com/apps?new_app=1${NC}\n"
    printf "    2. Choose \"From an app manifest\" → Select workspace\n"
    printf "    3. Paste the manifest from:\n"
    printf "       ${CYAN}${MANIFEST_TPL}${NC}\n"
    printf "       (Replace __AGENT_FULL_NAME__ with \"${AGENT_NAME}\"\n"
    printf "        and __AGENT_DISPLAY_NAME__ with \"${AGENT_NAME%% *}\")\n"
    echo ""
    printf "  ${BOLD}Option B:${NC} Set SLACK_CONFIG_TOKEN for API creation:\n"
    printf "    1. Go to ${CYAN}https://api.slack.com/apps${NC} → Your Apps\n"
    printf "    2. Settings → Configuration Tokens → Generate\n"
    printf "    3. Re-run with: ${BOLD}SLACK_CONFIG_TOKEN=xoxe-... $0 ...${NC}\n"
    echo ""
  fi

  if ! ${DRY_RUN}; then
    printf "Paste ${BOLD}App-Level Token${NC} (xapp-...), or press Enter to skip Slack: "
    read -r SLACK_APP_TOKEN

    if [[ -n "${SLACK_APP_TOKEN}" ]]; then
      if [[ ! "${SLACK_APP_TOKEN}" =~ ^xapp- ]]; then
        warn "App token usually starts with 'xapp-' — proceeding anyway"
      fi

      printf "Paste ${BOLD}Bot Token${NC} (xoxb-...): "
      read -r SLACK_BOT_TOKEN

      if [[ -n "${SLACK_BOT_TOKEN}" && ! "${SLACK_BOT_TOKEN}" =~ ^xoxb- ]]; then
        err "Bot token should start with 'xoxb-'"
        printf "Paste bot token: "
        read -r SLACK_BOT_TOKEN
      fi

      ok "Slack tokens collected"
    else
      warn "Skipping Slack — no app token provided"
      SKIP_SLACK=true
    fi
  fi
}

# ── Telegram setup ──────────────────────────────────────────────
TELEGRAM_BOT_TOKEN=""

setup_telegram() {
  header "Telegram"

  info "Telegram bots must be created via @BotFather (no API available)."
  echo ""
  printf "  ${BOLD}Steps:${NC}\n"
  printf "  1. Open ${CYAN}https://t.me/BotFather${NC}\n"
  printf "  2. Send: ${BOLD}/newbot${NC}\n"
  printf "  3. Name: ${BOLD}${AGENT_NAME} (OpenClaw)${NC}\n"
  printf "  4. Username suggestion: ${BOLD}openclaw_${AGENT_ID}_bot${NC}\n"
  printf "  5. Copy the bot token\n"
  echo ""

  if ! ${DRY_RUN}; then
    printf "Paste ${BOLD}Telegram Bot Token${NC}, or press Enter to skip Telegram: "
    read -r TELEGRAM_BOT_TOKEN

    if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
      # Basic format check: numeric_id:alphanumeric_hash
      if [[ ! "${TELEGRAM_BOT_TOKEN}" =~ ^[0-9]+: ]]; then
        warn "Token format looks unusual (expected <number>:<hash>) — proceeding anyway"
      fi
      ok "Telegram token collected"
    else
      warn "Skipping Telegram — no bot token provided"
      SKIP_TELEGRAM=true
    fi
  fi
}

# ── Write vault entries ─────────────────────────────────────────
write_vault() {
  header "Vault"

  local -a entries=()

  if ! ${SKIP_SLACK} && [[ -n "${SLACK_BOT_TOKEN}" ]]; then
    entries+=("vault_${AGENT_ID}_slack_bot_token=${SLACK_BOT_TOKEN}")
    entries+=("vault_${AGENT_ID}_slack_app_token=${SLACK_APP_TOKEN}")
  fi

  if ! ${SKIP_TELEGRAM} && [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    entries+=("vault_${AGENT_ID}_telegram_bot_token=${TELEGRAM_BOT_TOKEN}")
  fi

  if [[ ${#entries[@]} -eq 0 ]]; then
    warn "No tokens to store in vault"
    return
  fi

  vault_add_entries "${entries[@]}"
}

# ── Append agent to main.yml ───────────────────────────────────
write_agent_config() {
  header "Agent Config"

  if ${AGENT_EXISTS}; then
    # Agent entry exists — patch in channel blocks if tokens were provided
    local needs_patch=false
    local patch_lines=""

    if ! ${SKIP_SLACK} && [[ -n "${SLACK_BOT_TOKEN}" ]]; then
      needs_patch=true
      patch_lines+=$'\n'"    slack:"
      patch_lines+=$'\n'"      bot_token: \"{{ vault_${AGENT_ID}_slack_bot_token }}\""
      patch_lines+=$'\n'"      app_token: \"{{ vault_${AGENT_ID}_slack_app_token }}\""
    fi

    if ! ${SKIP_TELEGRAM} && [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
      needs_patch=true
      patch_lines+=$'\n'"    telegram:"
      patch_lines+=$'\n'"      bot_token: \"{{ vault_${AGENT_ID}_telegram_bot_token }}\""
    fi

    if ! ${needs_patch}; then
      ok "Agent '${AGENT_ID}' already in config, no channel tokens to add"
      return
    fi

    if ${DRY_RUN}; then
      info "[dry-run] Would add to agent '${AGENT_ID}':"
      echo "${patch_lines}"
      return
    fi

    # Find the agent's block and insert channel lines at the end of it.
    # Locate the "- id: <agent>" line, then find the last indented line
    # before the next list item (- id:) or top-level key.
    local agent_line
    agent_line="$(grep -n "id: \"${AGENT_ID}\"" "${MAIN_FILE}" | head -1 | cut -d: -f1)"
    local total_lines
    total_lines="$(wc -l < "${MAIN_FILE}")"
    local insert_after="${agent_line}"
    local line_num=$((agent_line + 1))

    while [[ ${line_num} -le ${total_lines} ]]; do
      local line
      line="$(sed -n "${line_num}p" "${MAIN_FILE}")"
      # Stop at next list item, top-level key, or blank line followed by non-indented content
      if [[ "${line}" =~ ^[[:space:]]*-[[:space:]] && ${line_num} -gt ${agent_line} ]]; then
        break
      fi
      if [[ -n "${line}" && ! "${line}" =~ ^[[:space:]] ]]; then
        break
      fi
      if [[ -n "${line}" && "${line}" =~ ^[[:space:]] ]]; then
        insert_after=${line_num}
      fi
      line_num=$((line_num + 1))
    done

    local tmpfile
    tmpfile="$(mktemp)"
    {
      head -n "${insert_after}" "${MAIN_FILE}"
      echo "${patch_lines}"
      tail -n "+$((insert_after + 1))" "${MAIN_FILE}"
    } > "${tmpfile}"
    mv "${tmpfile}" "${MAIN_FILE}"
    ok "Channel blocks added to agent '${AGENT_ID}' in ${MAIN_FILE}"
    return
  fi

  # Build the YAML block for the new agent
  local yaml_block=""
  yaml_block+="  - id: \"${AGENT_ID}\""
  if ${MAKE_DEFAULT}; then
    yaml_block+=$'\n'"    default: true"
  fi
  yaml_block+=$'\n'"    name: \"${AGENT_NAME}\""
  yaml_block+=$'\n'"    workspace_subdir: \"${AGENT_ID}\""
  yaml_block+=$'\n'"    memory_search: ${MEMORY_SEARCH}"

  if [[ -n "${STATE_REPO}" ]]; then
    yaml_block+=$'\n'"    state_repo: \"${STATE_REPO}\""
    yaml_block+=$'\n'"    state_path: \"${STATE_PATH:-agents/${AGENT_ID}}\""
  fi

  if ! ${SKIP_SLACK} && [[ -n "${SLACK_BOT_TOKEN}" || ${DRY_RUN} == true ]]; then
    yaml_block+=$'\n'"    slack:"
    yaml_block+=$'\n'"      bot_token: \"{{ vault_${AGENT_ID}_slack_bot_token }}\""
    yaml_block+=$'\n'"      app_token: \"{{ vault_${AGENT_ID}_slack_app_token }}\""
  fi

  if ! ${SKIP_TELEGRAM} && [[ -n "${TELEGRAM_BOT_TOKEN}" || ${DRY_RUN} == true ]]; then
    yaml_block+=$'\n'"    telegram:"
    yaml_block+=$'\n'"      bot_token: \"{{ vault_${AGENT_ID}_telegram_bot_token }}\""
  fi

  echo ""
  info "Agent YAML block:"
  echo "${yaml_block}"
  echo ""

  if ${DRY_RUN}; then
    info "[dry-run] Would append to ${MAIN_FILE}"
    return
  fi

  # Find the last line of openclaw_agents list and append after it.
  # Strategy: find the line number of the last agent entry's deepest
  # indented line before the next top-level key or EOF.
  local agents_start
  agents_start="$(grep -n "^openclaw_agents:" "${MAIN_FILE}" | head -1 | cut -d: -f1)"

  if [[ -z "${agents_start}" ]]; then
    err "Cannot find 'openclaw_agents:' in ${MAIN_FILE}"
    exit 1
  fi

  # Find the end of the agents block: next line that starts at column 0
  # (not indented, not a comment continuation) after agents_start
  local total_lines
  total_lines="$(wc -l < "${MAIN_FILE}")"
  local agents_end="${total_lines}"

  local line_num=$((agents_start + 1))
  while [[ ${line_num} -le ${total_lines} ]]; do
    local line
    line="$(sed -n "${line_num}p" "${MAIN_FILE}")"
    # Non-empty line that doesn't start with space/# is a new top-level key
    if [[ -n "${line}" && ! "${line}" =~ ^[[:space:]] && ! "${line}" =~ ^# ]]; then
      agents_end=$((line_num - 1))
      break
    fi
    line_num=$((line_num + 1))
  done

  # Strip trailing blank lines from agents block
  while [[ ${agents_end} -gt ${agents_start} ]]; do
    local line
    line="$(sed -n "${agents_end}p" "${MAIN_FILE}")"
    if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]]; then
      agents_end=$((agents_end - 1))
    else
      break
    fi
  done

  # Insert after agents_end
  local tmpfile
  tmpfile="$(mktemp)"
  {
    head -n "${agents_end}" "${MAIN_FILE}"
    echo ""
    echo "${yaml_block}"
    tail -n "+$((agents_end + 1))" "${MAIN_FILE}"
  } > "${tmpfile}"

  mv "${tmpfile}" "${MAIN_FILE}"
  ok "Agent '${AGENT_ID}' appended to ${MAIN_FILE}"
}

# ── Summary ─────────────────────────────────────────────────────
print_summary() {
  header "Summary"

  ok "Agent '${AGENT_ID}' (${AGENT_NAME}) onboarded"
  echo ""

  if ! ${SKIP_SLACK}; then
    if [[ -n "${SLACK_BOT_TOKEN}" ]]; then
      ok "Slack: configured (vault_${AGENT_ID}_slack_bot_token)"
    else
      warn "Slack: skipped"
    fi
  else
    info "Slack: skipped (--skip-slack)"
  fi

  if ! ${SKIP_TELEGRAM}; then
    if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
      ok "Telegram: configured (vault_${AGENT_ID}_telegram_bot_token)"
    else
      warn "Telegram: skipped"
    fi
  else
    info "Telegram: skipped (--skip-telegram)"
  fi

  echo ""
  info "Next steps:"
  printf "  1. Review: ${CYAN}${MAIN_FILE}${NC}\n"
  printf "  2. Deploy: ${CYAN}ansible-playbook playbook.yml --ask-become-pass --tags phase3${NC}\n"

  if [[ -n "${SLACK_APP_ID}" ]]; then
    echo ""
    printf "  Slack app dashboard: ${CYAN}https://api.slack.com/apps/${SLACK_APP_ID}${NC}\n"
  fi
}

# ── Main ────────────────────────────────────────────────────────
main() {
  header "Onboard Agent: ${AGENT_NAME} (${AGENT_ID})"

  if ${DRY_RUN}; then
    warn "DRY RUN — no changes will be made"
  fi

  if ! ${SKIP_SLACK}; then
    setup_slack
  fi

  if ! ${SKIP_TELEGRAM}; then
    setup_telegram
  fi

  write_vault
  write_agent_config
  print_summary
}

main
