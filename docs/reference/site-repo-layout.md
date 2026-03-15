# Site Config Repo Layout

Your site config repo is the deployment entry point. It contains everything
specific to your environment: network topology, model endpoints, agent
definitions, and encrypted secrets. This repo should be **private**.

## Directory Structure

```
my-site/
├── site.cfg                          # Platform repo path + version pin
├── run.sh                            # Entry point — wraps ansible-playbook
├── bootstrap-vault.yml               # One-time vault secret generation
├── inventory/
│   ├── hosts.yml                     # Host inventory
│   ├── group_vars/
│   │   └── agent_hosts/
│   │       ├── main.yml              # All deployment configuration
│   │       └── vault.yml             # Encrypted secrets (ansible-vault)
│   └── host_vars/
│       └── agent-host-1.yml          # Per-host overrides
├── .gitignore
└── README.md
```

## File Descriptions

### site.cfg

Points to the platform repo and optionally pins a version:

```ini
platform_path=../openclaw-hardened
# platform_version=v0.2.0
```

The `run.sh` script reads this to locate the playbook and roles.

### run.sh

Wrapper that sets `ANSIBLE_ROLES_PATH` and invokes `ansible-playbook` with
your inventory. All command-line arguments are passed through:

```bash
./run.sh --ask-vault-pass --ask-become-pass
./run.sh --ask-vault-pass --tags phase3 --limit agent-host-1
```

### bootstrap-vault.yml

Interactive playbook that generates initial secrets (gateway token, gateway
password, Locksmith token) and prompts for API keys. Run once before the
first deploy:

```bash
ansible-playbook bootstrap-vault.yml --ask-vault-pass
```

Idempotent — skips if `vault.yml` already exists.

### inventory/hosts.yml

Standard Ansible inventory. Hosts go in the `agent_hosts` group:

```yaml
all:
  children:
    agent_hosts:
      hosts:
        agent-host-1:
          ansible_host: 10.0.1.20
          ansible_user: deploy
```

### inventory/group_vars/agent_hosts/main.yml

The main configuration file. Contains all deployment settings: network
topology, inference endpoints, Pipelock overrides, agent definitions,
telemetry config. See the
[site config schema](../site-config-schema.md) for every variable.

Key sections:

| Section | Purpose |
|---------|---------|
| `openclaw_version` | Pinned OpenClaw version (e.g. `2026.3.12`) |
| `network` | Gateway IP, subnet, allowed LAN IPs, management CIDRs |
| `inference.endpoints` | Model providers (local and cloud) |
| `pipelock.api_allowlist_extra` | Additional domains for egress proxy |
| `openclaw` | Gateway settings, tools profile, sandbox mode |
| `ollama` | Local embedding model (optional) |
| `openclaw_agents` | Agent definitions with per-agent channel identities |
| `verify` | Inference endpoint health checks |

### inventory/group_vars/agent_hosts/vault.yml

Encrypted secrets. Managed with `ansible-vault edit`. Variable naming
convention:

| Pattern | Example |
|---------|---------|
| `vault_<agentid>_slack_bot_token` | `vault_alice_slack_bot_token` |
| `vault_<agentid>_slack_app_token` | `vault_alice_slack_app_token` |
| `vault_<agentid>_telegram_bot_token` | `vault_alice_telegram_bot_token` |
| `vault_openclaw_gateway_token` | Gateway bearer token |
| `vault_openclaw_gateway_password` | Gateway password |
| `vault_<provider>_api_key` | `vault_anthropic_api_key` |
| `vault_github_token` | GitHub PAT for agent state repos |
| `vault_locksmith_inbound_token` | Locksmith authentication |

### inventory/host_vars/agent-host-1.yml

Per-host overrides. Typically just the host IP and any host-specific
channel config:

```yaml
---
host_ip: "10.0.1.20"
openclaw_gateway_token: "{{ vault_openclaw_gateway_token }}"
openclaw_gateway_password: "{{ vault_openclaw_gateway_password }}"
```

## Getting Started

```bash
# 1. Create from examples
mkdir my-site && cd my-site
cp -r ../openclaw-hardened/examples/* .

# 2. Rename example files
mv main.yml.example inventory/group_vars/agent_hosts/main.yml
mv hosts.yml.example inventory/hosts.yml
mv host_vars.yml.example inventory/host_vars/agent-host-1.yml
mv bootstrap-vault.yml.example bootstrap-vault.yml

# 3. Edit configuration
$EDITOR inventory/group_vars/agent_hosts/main.yml

# 4. Bootstrap vault
ansible-playbook bootstrap-vault.yml --ask-vault-pass

# 5. Deploy
./run.sh --ask-vault-pass --ask-become-pass
```

## See Also

- [Site Config Schema](../site-config-schema.md) — complete variable reference
- [Installation Guide](../installation.md) — step-by-step first deployment
- [Operations Guide](../operations.md) — adding agents, models, rotating keys
