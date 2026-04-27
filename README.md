# openclaw-hardened

Security-hardened deployment framework for [OpenClaw](https://github.com/openclaw).

openclaw-hardened does not fork OpenClaw. It deploys alongside it as a set of
Ansible roles that layer defense-in-depth controls around a standard OpenClaw
installation and upgrade with it via declarative version pinning.

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │            Agent Host                │
                    │                                      │
 Slack/Telegram ──► │  OpenClaw ──► LlamaFirewall ──► Models
                    │     │              │                 │
                    │     ▼              ▼                 │
                    │  Locksmith    Pipelock ──────────────┼──► Internet
                    │  (credential    (HTTPS proxy,        │
                    │   injection)     domain allowlist,   │
                    │                  DLP scanning)       │
                    │                    │                 │
                    │              nftables                │
                    │         (default-drop egress)        │
                    └──────────────────────────────────────┘
```

**Security layers, inside out:**

1. **nftables** -- Default-drop egress firewall. Only explicitly allowed IPs and ports pass.
2. **Pipelock** -- HTTPS forward proxy with domain allowlist and data-loss prevention scanning.
3. **LlamaFirewall** -- Inference proxy with PromptGuard 2 prompt injection detection, CodeShield static analysis, and per-provider budget enforcement.
4. **Locksmith** -- Credential injection proxy. Agents call tool APIs through Locksmith; credentials never enter the agent process.
5. **Config lockdown** -- Root-owned OpenClaw configuration file, immutable to the agent user.

## Three-Repo Model

openclaw-hardened uses a separation between public roles, private site
configuration, and private agent state:

| Repository | Visibility | Contents |
|------------|------------|----------|
| [SentientSwarm/openclaw-hardened](https://github.com/SentientSwarm/openclaw-hardened) | Public | Ansible roles, playbook, examples |
| `your-org/openclaw-hardened-site` | Private | Site config, inventory, Ansible Vault secrets |
| `your-org/openclaw-agents` | Private | Agent workspaces, memory databases, skills |

The **site repo** is the operational entry point. It contains `run.sh`, which
wraps `ansible-playbook` with the correct inventory, config, and vault
arguments.

## Quick Start

### Prerequisites

- **Target host**: Ubuntu 22.04+ with SSH and sudo access
- **Control machine**: Ansible 2.15+
- **Ansible collections**:
  ```bash
  ansible-galaxy collection install -r requirements.yml
  ```

### Deploy

```bash
# 1. Clone openclaw-hardened
git clone https://github.com/SentientSwarm/openclaw-hardened.git

# 2. Create your site config repo
mkdir my-site && cd my-site
cp -r ../openclaw-hardened/examples/* .
git init

# 3. Edit site config
#    - hosts.yml        : target host IP and SSH user
#    - main.yml         : network topology, inference endpoints, agents
#    - host_vars.yml    : per-host secrets and channel config
#    See docs/site-config-schema.md for all variables.

# 4. Bootstrap vault secrets
ansible-playbook bootstrap-vault.yml --ask-vault-pass

# 5. Deploy (all phases)
./run.sh --ask-vault-pass --ask-become-pass
```

## Deployment Phases

| Phase | Tag | What it does |
|-------|-----|--------------|
| 1 -- Bootstrap | `bootstrap` | System user, Docker, Node.js, pnpm, OpenClaw binary, fail2ban |
| 2 -- Hardening | `phase2` | gVisor, Pipelock, nftables, LlamaFirewall, Locksmith, Ollama, telemetry |
| 3 -- Configuration | `phase3` | Onboard, render `openclaw.json`, systemd service, agent state |
| Verify | `verify` | Automated security posture checks |

Run individual phases with `--tags`:

```bash
./run.sh --ask-vault-pass --ask-become-pass --tags bootstrap
./run.sh --ask-vault-pass --ask-become-pass --tags verify
```

If you manage Phase 1 externally (your own provisioning tooling), set
`bootstrap.enabled: false` in your site config. The playbook will verify
that the `openclaw` user and Docker exist before proceeding.

## Key Features

### Declarative Version Pinning

Pin the OpenClaw release in your site config. Upgrades are a one-line
change followed by `./run.sh`.

### Per-Agent Channel Identities

Each agent can have its own Slack and Telegram bot tokens. OpenClaw runs in
multi-account mode with per-agent routing (bindings), so multiple agents
share a host without sharing channel identities.

### Local Embeddings

When Ollama is enabled, agents use local embedding models for memory search
instead of calling external APIs.

### Telemetry Stack

Optional observability stack deployed as part of Phase 2:

- **OpenTelemetry Collector** -- OTLP ingest (gRPC + HTTP)
- **Prometheus** -- Metrics storage and alerting
- **Phoenix** -- LLM trace visualization
- **Grafana** -- Dashboards
- **Loki** -- Log aggregation
- **Caddy** -- TLS termination for telemetry UIs

### Sandbox Status

Container sandboxing via gVisor is configured but currently disabled at the
OpenClaw layer due to path restrictions in the OpenClaw sandbox
implementation. The gVisor runtime is installed and set as the default
Docker runtime; mitigation details are documented in
[docs/security.md](docs/security.md).

## Dependencies

| Component | Role | Source |
|-----------|------|--------|
| [OpenClaw](https://github.com/openclaw) | AI agent platform | npm release or source build |
| [Pipelock](https://github.com/SentientSwarm/pipelock) | HTTPS proxy with domain allowlist + DLP | Container image |
| [LlamaFirewall](https://github.com/meta-llama/PurpleLlama) | Inference proxy, prompt injection scanning, budget | Python (venv) |
| [agent-locksmith](https://github.com/SentientSwarm/agent-locksmith) | Credential injection proxy | Container image |
| Docker | Container runtime | System package |
| gVisor (runsc) | Sandboxed container runtime | System package |
| Ollama | Local embedding models (optional) | System package |
| Ansible 2.15+ | Deployment automation | Control machine |

## Documentation

- [Architecture](docs/architecture.md) -- System design and security model
- [Host-Side Pipelock and Locksmith](docs/host-side-pipelock-locksmith.md) -- Target architecture for host-enforced gateway/untrusted VM deployments
- [Installation](docs/installation.md) -- Detailed setup walkthrough
- [Operations](docs/operations.md) -- Day-to-day management, upgrades, troubleshooting
- [Security](docs/security.md) -- Threat model, layer details, sandbox mitigations
- [Site Config Schema](docs/site-config-schema.md) -- All configuration variables
- [Site Repo Layout](docs/reference/site-repo-layout.md) -- Structure of the private site config repo
- [Agents Repo Layout](docs/reference/agents-repo-layout.md) -- Structure of the private agents repo

## License

[MIT](LICENSE)
