# Operations Guide

Day-to-day procedures for managing an openclaw-hardened deployment.

## Adding a New Agent

### Automated (onboard script)

The onboard script handles Slack app creation, Telegram setup guidance,
vault entries, and agent config:

```bash
cd openclaw-hardened
./scripts/onboard-agent.sh --id bob --name "Bob" \
  --site-dir /path/to/my-site \
  --state-repo "git@github.com:your-org/my-agents.git"
```

Options:
- `--skip-slack` / `--skip-telegram` — skip channel setup
- `--dry-run` — preview without changes
- `--default` — make this the default agent

The script will:
1. Create Slack app via Manifest API (if `SLACK_CONFIG_TOKEN` is set) or
   guide manual creation
2. Walk through Telegram BotFather bot creation
3. Print vault entries to add with `ansible-vault edit`
4. Append the agent definition to site config

### Manual steps

1. **Create workspace in agents repo:**
   ```bash
   cd my-agents
   mkdir -p agents/bob/{workspace/skills,memory/dumps,sessions}
   # Copy SOUL.md, IDENTITY.md templates
   git add agents/bob && git commit -m "Add Bob agent" && git push
   ```

2. **Add agent to site config** (`main.yml`):
   ```yaml
   openclaw_agents:
     # ... existing agents ...
     - id: "bob"
       name: "Bob"
       workspace_subdir: "bob"
       memory_search: true
       state_repo: "git@github.com:your-org/my-agents.git"
       state_path: "agents/bob"
       slack:
         bot_token: "{{ vault_bob_slack_bot_token }}"
         app_token: "{{ vault_bob_slack_app_token }}"
       telegram:
         bot_token: "{{ vault_bob_telegram_bot_token }}"
   ```

3. **Add tokens to vault:**
   ```bash
   ansible-vault edit inventory/group_vars/agent_hosts/vault.yml
   ```
   Add:
   ```yaml
   vault_bob_slack_bot_token: "xoxb-..."
   vault_bob_slack_app_token: "xapp-..."
   vault_bob_telegram_bot_token: "..."
   ```

4. **Deploy:**
   ```bash
   ./run.sh --ask-vault-pass --tags phase3
   ```

5. **Approve pairings** (after first message from each channel):
   ```bash
   ssh agent-host-1 "sudo -u openclaw /home/openclaw/.local/bin/openclaw pairing approve slack <CODE>"
   ssh agent-host-1 "sudo -u openclaw /home/openclaw/.local/bin/openclaw pairing approve telegram <CODE>"
   ```

### Creating a Slack App

The easiest method is via the app manifest:

1. Go to https://api.slack.com/apps?new_app=1
2. Choose "From an app manifest" and select your workspace
3. Paste the manifest from `scripts/slack-manifest.json.tpl` (replace
   `__AGENT_DISPLAY_NAME__` with the agent's name)
4. Install to workspace
5. Copy the Bot Token (xoxb-...) from OAuth & Permissions
6. Generate an App-Level Token (xapp-...) from Basic Information with
   `connections:write` scope
7. In App Home, enable Messages Tab and check "Allow users to send Slash
   commands and messages from the messages tab"

### Enabling Inter-Agent Group Chat

To let agents communicate in a shared Telegram group:

1. Add `group_allow_from` to each agent's telegram config with the other
   agents' bot UIDs and your own user ID:
   ```yaml
   telegram:
     bot_token: "{{ vault_alice_telegram_bot_token }}"
     group_allow_from:
       - "123456789"   # Your Telegram user ID
       - "987654321"   # Bob's bot user ID
   ```
   Bot user IDs are the numeric prefix of the bot token (before the colon).

2. Redeploy: `./run.sh --ask-vault-pass --tags config`

3. Create a Telegram group and add both bots

## Adding a New Model

### Local endpoint (Kamiwaza, Ollama, vLLM)

1. Deploy the model on your inference server

2. Add to `inference.endpoints` in site config:
   ```yaml
   - provider_name: "my-local-model"
     base_url: "https://10.0.1.10/runtime/models/<id>/v1"
     api_type: "openai-completions"
     api_key: "not-required"
     model_id: "Model-Name"
     model_name: "Model Name (My Server)"
     context_window: 32768
     max_tokens: 4096
     primary: false
     tls_skip_verify: true
   ```

3. Redeploy LlamaFirewall to register the new upstream, then config:
   ```bash
   ./run.sh --ask-vault-pass --tags llamafirewall,config
   ```

Note: endpoints with `api_key: "not-required"` are treated as
unauthenticated — LlamaFirewall skips auth header injection for them.

### Cloud endpoint

1. Add the API key to vault:
   ```bash
   ansible-vault edit inventory/group_vars/agent_hosts/vault.yml
   # Add: vault_newprovider_api_key: "sk-..."
   ```

2. Add to `inference.endpoints`:
   ```yaml
   - provider_name: "newprovider"
     location: "cloud"
     base_url: "https://api.newprovider.com/v1"
     api_type: "openai-completions"
     api_key: "{{ vault_newprovider_api_key }}"
     api_key_header: "Authorization"
     api_key_prefix: "Bearer"
     model_id: "model-name"
     model_name: "Model Name (Provider)"
     context_window: 128000
     max_tokens: 8192
     primary: false
   ```

3. Add the domain to Pipelock allowlist:
   ```yaml
   pipelock:
     api_allowlist_extra:
       - "api.newprovider.com"
   ```

4. Redeploy:
   ```bash
   ./run.sh --ask-vault-pass --tags pipelock,llamafirewall,config
   ```

### Changing the primary model

Set `primary: true` on the desired endpoint and `primary: false` on the
old one, then redeploy config:

```bash
./run.sh --ask-vault-pass --tags config
```

## Upgrading OpenClaw

1. Set the target version in site config:
   ```yaml
   openclaw_version: "2026.3.12"
   ```

2. Run the service tag:
   ```bash
   ./run.sh --ask-vault-pass --tags service
   ```

The upgrade task will:
1. Stop OpenClaw
2. Stop Pipelock
3. Open a temporary nftables egress rule for the `openclaw` user
4. Run `pnpm add -g openclaw@<version>`
5. Remove the temporary rule
6. Start Pipelock and verify
7. Start OpenClaw
8. Run posture verification

**Why not upgrade through Pipelock?** pnpm's HTTPS CONNECT tunnel
implementation is incompatible with Pipelock's proxy. The temporary
nftables rule is the only reliable approach. It is active for the duration
of the install only (typically 5-30 seconds).

Set `openclaw_version: "latest"` to skip version management entirely.

## Rotating Secrets

### Gateway token and password

```bash
# Generate new values
openssl rand -hex 24    # token
openssl rand -base64 16 # password

# Update vault
ansible-vault edit inventory/group_vars/agent_hosts/vault.yml

# Redeploy
./run.sh --ask-vault-pass --tags config
```

Update any clients using the old credentials.

### Slack and Telegram tokens

1. Regenerate in the Slack dashboard or via BotFather
2. Update vault with new per-agent token values
3. Redeploy: `./run.sh --ask-vault-pass --tags config`

### API keys (inference providers)

1. Rotate in the provider dashboard
2. Update vault
3. Redeploy: `./run.sh --ask-vault-pass --tags llamafirewall`
   (LlamaFirewall injects the keys, not OpenClaw)

### GitHub token (agent state repos)

1. Generate new PAT in GitHub
2. Update `vault_github_token` in vault
3. Redeploy: `./run.sh --ask-vault-pass --tags agents`

## Adding a Pipelock Domain

When agents need access to a new external service:

```yaml
pipelock:
  api_allowlist_extra:
    - "api.newservice.com"
    - "*.newservice.com"    # Wildcard supported
```

```bash
./run.sh --ask-vault-pass --tags pipelock
```

Pipelock supports hot-reload via SIGHUP, but redeploying via Ansible
ensures the config is persisted.

## Enabling Local Embeddings (Ollama)

For memory search without cloud dependencies:

```yaml
ollama:
  enabled: true
  embedding_model: "nomic-embed-text"    # 274MB, fast, good quality
```

```bash
./run.sh --ask-vault-pass --tags ollama,config
```

Ensure `memory_search: true` is set on agents that should use it.

Ollama binds to `127.0.0.1:11434` — no Pipelock or nftables changes
needed for inference. Model pulls use a temporary nftables egress rule
(same pattern as OpenClaw upgrades).

## Enabling Telemetry

```yaml
telemetry:
  enabled: true
```

```bash
./run.sh --ask-vault-pass --tags telemetry
```

This deploys: OTel Collector, Prometheus, Phoenix (LLM observability),
Grafana, Loki (log aggregation), and Caddy (TLS-terminating reverse proxy).

Access dashboards via the Caddy HTTPS ports configured in
`telemetry.caddy.*_port`.

## Troubleshooting

### Agent not responding on Slack/Telegram

1. Check the service:
   ```bash
   ssh agent-host-1 "sudo systemctl status openclaw"
   ssh agent-host-1 "sudo journalctl -u openclaw -f"
   ```

2. Common causes:
   - **Memory search timeout** — if no embedding provider is configured,
     set `memory_search: false` on the agent or enable Ollama
   - **Sandbox path escape** — set `sandbox.mode: "off"` (see
     [Security Model](security.md#sandbox-status))
   - **Pairing not approved** — check for pairing codes in the chat and
     run `openclaw pairing approve`
   - **Slack Messages Tab disabled** — in the app dashboard, ensure App
     Home has Messages Tab enabled with "Allow users to send Slash
     commands and messages"

### Agent stuck / not calling tools

Check the model's tool-calling capability. Some models (particularly
smaller ones) may generate text about using tools without actually making
tool calls. Symptoms: `stopReason: stop` instead of `stopReason: toolUse`
in session transcripts.

Fix: switch to a model with strong tool-calling support (Claude, GPT-4o,
or distilled models trained on tool use).

### Egress blocked

1. Check nftables kernel logs:
   ```bash
   ssh agent-host-1 "sudo journalctl -k | grep nft-egress-block | tail -10"
   ```

2. Check if the domain is in the Pipelock allowlist:
   ```bash
   ssh agent-host-1 "sudo cat /etc/pipelock/pipelock.yaml | grep allowlist -A 30"
   ```

3. Test through the proxy:
   ```bash
   ssh agent-host-1 "curl -sv --proxy http://127.0.0.1:8888 https://example.com"
   ```

4. Add the domain to `pipelock.api_allowlist_extra` and redeploy

### Model not reachable

1. Check LlamaFirewall health:
   ```bash
   ssh agent-host-1 "curl -s http://127.0.0.1:9100/health"
   ```
   Verify the provider is listed in `upstreams`.

2. If missing, redeploy: `./run.sh --ask-vault-pass --tags llamafirewall`

3. For `api_key: "not-required"` endpoints, ensure the LlamaFirewall
   template handles unauthenticated upstreams (the `not-required` value
   should be treated as no auth).

### Token leakage in Ansible output

Ensure tasks looping over `openclaw_agents` use `loop_control: label`:
```yaml
loop_control:
  label: "{{ item.id }}"
```

This prevents the full agent dict (including tokens) from appearing in
console output.

## See Also

- [Architecture](architecture.md) — security layer design
- [Installation Guide](installation.md) — first deployment
- [Security Model](security.md) — threat model and hardening
- [Site Config Schema](site-config-schema.md) — variable reference
