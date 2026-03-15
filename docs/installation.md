# Installation Guide

This guide walks through deploying OpenClaw with the full security stack
on a fresh Ubuntu host. By the end, you will have a running agent accessible
via Slack, Telegram, and the gateway UI.

## Prerequisites

### Control Machine (where you run Ansible)

- Python 3.10+
- Ansible 2.15+
- Git
- SSH access to the target host (key-based recommended)

```bash
pip install ansible
ansible-galaxy collection install -r requirements.yml
```

### Target Host

- Ubuntu 22.04+ or Debian 12+
- SSH access with a user that has sudo privileges
- At least 4GB RAM, 2 CPU cores, 20GB disk
- Internet access (the bootstrap phase installs packages)

GPU is not required — inference can run on remote endpoints (Kamiwaza,
cloud providers) or CPU-based local models (Ollama).

## Step 1: Clone the Platform Repo

```bash
git clone https://github.com/SentientSwarm/openclaw-hardened.git
cd openclaw-hardened
ansible-galaxy collection install -r requirements.yml
```

This is the public platform repo. It contains Ansible roles, templates, and
examples. You will not modify files in this repo — all customization goes in
your private site config repo.

## Step 2: Create Your Site Config Repo

```bash
mkdir ../my-site && cd ../my-site
git init

# Copy example files
mkdir -p inventory/group_vars/agent_hosts inventory/host_vars
cp ../openclaw-hardened/examples/main.yml.example inventory/group_vars/agent_hosts/main.yml
cp ../openclaw-hardened/examples/hosts.yml.example inventory/hosts.yml
cp ../openclaw-hardened/examples/host_vars.yml.example inventory/host_vars/agent-host-1.yml
cp ../openclaw-hardened/examples/bootstrap-vault.yml.example bootstrap-vault.yml

# Create site.cfg
cat > site.cfg << 'EOF'
platform_path=../openclaw-hardened
EOF

# Create run.sh
cat > run.sh << 'RUNEOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/site.cfg"
PLATFORM="${SCRIPT_DIR}/${platform_path}"
if [[ ! -d "$PLATFORM" ]]; then
    echo "ERROR: Platform repo not found at $PLATFORM"
    exit 1
fi
export ANSIBLE_ROLES_PATH="$PLATFORM/roles"
ansible-playbook -i "$SCRIPT_DIR/inventory" "$PLATFORM/playbook.yml" "$@"
RUNEOF
chmod +x run.sh
```

See [Site Repo Layout](reference/site-repo-layout.md) for the full
directory structure reference.

## Step 3: Configure Your Network

Edit `inventory/group_vars/agent_hosts/main.yml`. Start with the network
section:

```yaml
network:
  gateway_ip: "10.0.1.1"        # Your default gateway
  dns_server: "10.0.1.1"        # DNS server
  subnet: "10.0.1.0/24"         # LAN subnet

  allowed_lan_ips:
    - { ip: "10.0.1.1", comment: "gateway" }
    - { ip: "10.0.1.10", comment: "inference server" }

  mgmt_cidrs:
    - { cidr: "10.0.1.0/24", comment: "LAN management" }
```

Update `inventory/hosts.yml` with your target host:

```yaml
all:
  children:
    agent_hosts:
      hosts:
        agent-host-1:
          ansible_host: 10.0.1.20
          ansible_user: deploy
```

And `inventory/host_vars/agent-host-1.yml`:

```yaml
host_ip: "10.0.1.20"
openclaw_gateway_token: "{{ vault_openclaw_gateway_token }}"
openclaw_gateway_password: "{{ vault_openclaw_gateway_password }}"
```

## Step 4: Add Inference Endpoints

Add at least one model provider to the `inference.endpoints` list:

### Cloud provider (e.g., Anthropic)

```yaml
inference:
  endpoints:
    - provider_name: "anthropic"
      location: "cloud"
      base_url: "https://api.anthropic.com/v1"
      api_type: "anthropic-messages"
      api_key: "{{ vault_anthropic_api_key }}"
      api_key_header: "x-api-key"
      model_id: "claude-sonnet-4-20250514"
      model_name: "Claude Sonnet 4 (Anthropic)"
      context_window: 200000
      max_tokens: 8192
      reasoning: false
      primary: true
      params:
        temperature: 0.7
```

### Local model (e.g., Kamiwaza)

```yaml
    - provider_name: "local-llama"
      base_url: "https://10.0.1.10/runtime/models/<deployment-id>/v1"
      api_type: "openai-completions"
      api_key: "not-required"
      model_id: "my-model"
      model_name: "My Local Model"
      context_window: 32768
      max_tokens: 4096
      primary: false
      tls_skip_verify: true       # For self-signed certs
```

Add cloud provider domains to the Pipelock allowlist:

```yaml
pipelock:
  api_allowlist_extra:
    - "api.anthropic.com"         # Already in defaults
    - "api.openai.com"            # Already in defaults
    - "your-custom-provider.com"
```

## Step 5: Bootstrap the Vault

Generate initial secrets:

```bash
ansible-playbook bootstrap-vault.yml --ask-vault-pass
```

This prompts for API keys and generates gateway credentials. The result is
an encrypted `inventory/group_vars/agent_hosts/vault.yml`.

To add secrets later:

```bash
ansible-vault edit inventory/group_vars/agent_hosts/vault.yml
```

## Step 6: Create Your Agents Repo

```bash
mkdir ../my-agents && cd ../my-agents
git init
mkdir -p shared/knowledge agents/alice/{workspace/skills,memory/dumps,sessions}
```

Create minimal workspace files:

```bash
cat > agents/alice/workspace/IDENTITY.md << 'EOF'
# IDENTITY.md - Who Am I?

- **Name:** Alice
- **Vibe:** Helpful, direct, competent
- **Emoji:** _(pick one)_
EOF

cp /path/to/openclaw-hardened/examples/SOUL.md agents/alice/workspace/SOUL.md
```

See [Agent State Repo Layout](reference/agents-repo-layout.md) for
the full directory structure reference.

Push to a private Git repo:

```bash
git add . && git commit -m "Initial agent state"
git remote add origin git@github.com:your-org/my-agents.git
git push -u origin main
```

## Step 7: Define Your First Agent

In your site config (`main.yml`), add the agent definition:

```yaml
openclaw_agents:
  - id: "alice"
    default: true
    name: "Alice"
    workspace_subdir: "alice"
    memory_search: true
    skills: []
    state_repo: "git@github.com:your-org/my-agents.git"
    state_path: "agents/alice"
```

To add Slack or Telegram identity, see the
[Operations Guide](operations.md#adding-a-new-agent).

## Step 8: Deploy

Full deployment (all phases):

```bash
./run.sh --ask-vault-pass --ask-become-pass
```

This takes 10-15 minutes on a fresh host. For subsequent runs, deploy
specific phases:

```bash
# Just config + service (fastest)
./run.sh --ask-vault-pass --tags phase3

# Just hardening
./run.sh --ask-vault-pass --tags phase2

# Single host
./run.sh --ask-vault-pass --tags phase3 --limit agent-host-1
```

## Step 9: Verify

The `verify` role runs automatically after deployment. You can also run it
separately:

```bash
./run.sh --ask-vault-pass --tags verify
```

Manual checks:

```bash
# Gateway responding
curl -sk https://<host-ip>:18789/api/health

# Services running
ssh agent-host-1 "systemctl is-active openclaw pipelock llamafirewall"

# Pipelock enforcing
ssh agent-host-1 "curl -s http://127.0.0.1:8888/health"

# LlamaFirewall healthy
ssh agent-host-1 "curl -s http://127.0.0.1:9100/health"
```

## Post-Install Options

### Enable local embeddings (Ollama)

For memory search without cloud API dependencies:

```yaml
ollama:
  enabled: true
  embedding_model: "nomic-embed-text"
```

```bash
./run.sh --ask-vault-pass --tags ollama,config
```

### Enable telemetry

```yaml
telemetry:
  enabled: true
```

```bash
./run.sh --ask-vault-pass --tags telemetry
```

### Enable Locksmith (credential proxy)

```yaml
locksmith:
  enabled: true
  tools:
    - name: "github"
      upstream: "https://api.github.com"
      cloud: true
      auth:
        header: "Authorization"
        value: "Bearer {{ vault_github_token }}"
```

```bash
./run.sh --ask-vault-pass --tags locksmith
```

## Upgrading from openclaw-deploy

If you previously used the single-repo `openclaw-deploy` layout:

1. Your `group_vars/` and `host_vars/` content moves to the site repo
2. Agent workspace files move to the agents repo
3. Role defaults are now in `openclaw-hardened/roles/*/defaults/main.yml`
4. The `run.sh` / `site.cfg` pattern replaces the in-repo inventory

## See Also

- [Architecture](architecture.md) — security layer design
- [Operations Guide](operations.md) — day-to-day tasks
- [Security Model](security.md) — threat model and hardening
- [Site Config Schema](site-config-schema.md) — every variable documented
