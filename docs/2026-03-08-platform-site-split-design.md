# Platform / Site Config Split — Design

## Goal

Split openclaw-deploy into a public platform repo and a private site config repo so the infrastructure can be shared without exposing site-specific IPs, model endpoints, vault secrets, or agent definitions.

## Architecture

Three repos under SentientSwarm, each with a distinct responsibility:

- **openclaw-hardened** (public): Ansible roles, playbook, templates, role defaults. No site-specific values.
- **openclaw-hardened-site** (private): Inventory, group_vars, vault, bootstrap, agent definitions. Everything unique to a deployment.
- **openclaw-agents** (private): Per-agent state — workspaces, memory dumps, skills. Shared knowledge files.

## Repository Layout

### openclaw-hardened (public)

```
openclaw-hardened/
├── playbook.yml
├── ansible.cfg                    # No inventory path; set by run.sh
├── CHANGELOG.md
├── docs/
│   ├── site-config-schema.md      # Every variable documented
│   ├── adding-models.md
│   └── cloud-provider-design.md
├── examples/
│   ├── main.yml.example           # Full site config with placeholders
│   ├── hosts.yml.example
│   ├── host_vars.yml.example
│   └── bootstrap-vault.yml.example
└── roles/
    ├── docker_hardening/
    │   └── defaults/main.yml
    ├── pipelock/
    │   └── defaults/main.yml
    ├── locksmith/
    │   └── defaults/main.yml
    ├── nftables/
    │   └── defaults/main.yml
    ├── llamafirewall/
    │   └── defaults/main.yml
    ├── openclaw_onboard/
    ├── openclaw_config/
    │   └── defaults/main.yml
    ├── openclaw_service/
    ├── agent_state/               # NEW: clone repos, link workspaces, restore memory
    │   └── tasks/main.yml
    ├── otel_collector/
    │   └── defaults/main.yml
    ├── prometheus/
    │   └── defaults/main.yml
    ├── phoenix/
    │   └── defaults/main.yml
    ├── grafana/
    │   └── defaults/main.yml
    ├── caddy/
    │   └── defaults/main.yml
    └── verify/
```

### openclaw-hardened-site (private)

```
openclaw-hardened-site/
├── run.sh                         # Wrapper for ansible-playbook
├── site.cfg                       # Platform path + advisory version
├── bootstrap-vault.yml            # Site-specific secret prompts
├── inventory/
│   ├── hosts.yml
│   └── host_vars/
│       └── evo-x2-1.yml
└── group_vars/
    └── agent_hosts/
        ├── main.yml               # Network, endpoints, agents, feature flags
        └── vault.yml              # Encrypted secrets
```

### openclaw-agents (private)

```
openclaw-agents/
├── shared/
│   └── knowledge/
│       └── kamiwaza-agentic-employee-handbook.md
└── agents/
    └── mira/
        ├── workspace/
        │   ├── SOUL.md
        │   ├── IDENTITY.md
        │   ├── AGENTS.md
        │   ├── USER.md
        │   ├── TOOLS.md
        │   ├── BOOTSTRAP.md
        │   ├── HEARTBEAT.md
        │   └── skills/
        │       └── clawsec-suite/
        └── memory/
            └── dumps/main.sql
```

## Variable Split

### Platform defaults (roles/*/defaults/main.yml)

Generic values that work for any deployment. Users override in site config only when needed.

| Role | Key Defaults |
|------|-------------|
| docker_hardening | `default_runtime: runsc`, `no_new_privileges: true`, `log_max_size: 10m` |
| pipelock | `mode: balanced`, `enforce: true`, common `api_allowlist`, `blocklist`, `dlp` settings |
| locksmith | `listen_host: 127.0.0.1`, `listen_port: 9200`, `log_level: info` |
| llamafirewall | `listen_port: 9100`, `promptguard.enabled: true`, `codeshield.enabled: true`, `budget.default_monthly_usd: 50.00` |
| openclaw_config | `sandbox.mode: non-main`, `sandbox.memory: 2g`, `sandbox.cpus: 2`, `max_concurrent: 4`, `deny_commands` list |
| nftables | `docker_cidr: 172.16.0.0/12`, `inference_ports: [443, 11434, 8091]` |
| Telemetry roles | Service versions, ports, retention periods |

### Site config (group_vars/agent_hosts/main.yml)

Required site-specific values:

```yaml
network:
  gateway_ip: "192.168.50.1"
  dns_server: "192.168.50.1"
  subnet: "192.168.50.0/24"
  allowed_lan_ips:
    - { ip: "192.168.50.13", comment: "inference-1" }
  mgmt_cidrs:
    - { cidr: "192.168.50.0/24", comment: "LAN" }

inference:
  endpoints:
    - provider_name: "my-model"
      base_url: "https://192.168.50.13/v1"
      model_id: "My-Model"
      # ... full endpoint config

locksmith:
  enabled: true
  tools:
    - name: "github"
      upstream: "https://api.github.com"
      api_key: "{{ vault_github_token }}"
      # ...

llamafirewall:
  enabled: true

telemetry:
  enabled: true

openclaw_agents:
  - id: "main"
    name: "Mira"
    skills: ["clawsec-suite"]
    memory_search: true
    state_repo: "git@github.com:SentientSwarm/openclaw-agents.git"
    state_path: "agents/mira"

verify:
  inference_endpoints:
    - { name: "my-model", url: "https://192.168.50.13/api/ping" }
```

**Principle:** If it contains an IP, hostname, UUID, or vault reference, it belongs in site config. Everything else is a platform default.

Optional overrides: any role default can be overridden in site config.

### Per-host overrides (host_vars/)

```yaml
host_ip: "192.168.50.20"
openclaw_channels:
  telegram:
    enabled: true
    botToken: "{{ vault_telegram_bot_token }}"
```

## run.sh Wrapper

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/site.cfg"

PLATFORM="${SCRIPT_DIR}/${platform_path}"

if [[ ! -d "$PLATFORM" ]]; then
    echo "ERROR: Platform repo not found at $PLATFORM"
    echo "Clone it: git clone https://github.com/SentientSwarm/openclaw-hardened.git $PLATFORM"
    exit 1
fi

if [[ -n "${platform_version:-}" ]]; then
    actual=$(git -C "$PLATFORM" describe --tags --always 2>/dev/null || echo "unknown")
    if [[ "$actual" != "$platform_version" ]]; then
        echo "WARNING: Expected platform $platform_version, found $actual"
        echo "Run: cd $PLATFORM && git checkout $platform_version"
        read -rp "Continue anyway? [y/N] " yn
        [[ "$yn" =~ ^[Yy] ]] || exit 1
    fi
fi

export ANSIBLE_ROLES_PATH="$PLATFORM/roles"
ansible-playbook -i "$SCRIPT_DIR/inventory" "$PLATFORM/playbook.yml" "$@"
```

## Agent State Role

New `agent_state` role in the platform. Clones agent state repos, links workspaces, restores memory.

**For each agent in `openclaw_agents`:**

1. Clone `state_repo` once (deduplicated by repo URL) via Pipelock
2. Symlink `{state_path}/workspace/` into `/home/openclaw/.openclaw/agents/{id}/workspace`
3. Symlink `shared/` into `/home/openclaw/.openclaw/shared`
4. Restore SQLite from `{state_path}/memory/dumps/main.sql` if dump exists and DB doesn't
5. Set ownership to `openclaw:openclaw`

**openclaw.json.j2 changes:**

The agents section gains a `list` array generated from `openclaw_agents`:

```json
"agents": {
  "defaults": { ... },
  "list": [
    {
      "id": "main",
      "name": "Mira",
      "workspace": "/home/openclaw/.openclaw/agents/main/workspace",
      "skills": ["clawsec-suite"],
      "memorySearch": {
        "enabled": true,
        "extraPaths": ["/home/openclaw/.openclaw/shared/knowledge"]
      }
    }
  ]
}
```

## Upgrade Flow

```bash
cd openclaw-hardened && git fetch && git checkout v0.4.0
cat CHANGELOG.md                           # Check for new required variables
cd ../openclaw-hardened-site
sed -i '' 's/platform_version=.*/platform_version=v0.4.0/' site.cfg
./run.sh --tags phase2,phase3 --ask-vault-pass
```

## New User Setup

```bash
git clone https://github.com/SentientSwarm/openclaw-hardened.git
mkdir openclaw-hardened-site
cp openclaw-hardened/examples/* openclaw-hardened-site/
cd openclaw-hardened-site
# Edit inventory, group_vars, then:
ansible-playbook bootstrap-vault.yml --ask-vault-pass
./run.sh --ask-vault-pass --ask-become-pass
```

## Future Milestones

### Multi-host topology

Centralized proxy host serving multiple agent hosts. Requires:
- Two-play playbook (proxy_hosts + agent_hosts)
- Proxy services (Pipelock, Locksmith, LlamaFirewall) listen on 0.0.0.0
- Agent hosts point proxy URLs to the proxy host IP
- Separate nftables profiles for proxy vs agent hosts
- Shared telemetry collection

### Other

- Locksmith multi-token support (per-org GitHub tokens)
- Agent hot-reload without gateway restart
- Automated platform version compatibility checking in run.sh
