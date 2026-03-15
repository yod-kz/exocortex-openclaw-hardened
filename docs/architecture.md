# Architecture

This document describes the security architecture of **openclaw-hardened**,
an Ansible-based security wrapper for [OpenClaw](https://github.com/open-claw/open-claw)
(an AI agent platform). It is written for developers who want to understand
how the layers fit together, why each exists, and where to look in the
codebase for implementation details.

---

## Design Philosophy

**Defense in depth.** No single layer is the whole story. An agent that
bypasses one control still faces others. The firewall prevents proxy bypass;
the proxy prevents data exfiltration; the inference scanner prevents prompt
injection; the credential proxy prevents secret exposure. Each layer
assumes the others might fail.

**Wrapper, not fork.** OpenClaw is an upstream project that evolves
independently. openclaw-hardened deploys security layers *alongside* it
rather than patching its source code. The only touch point is
`openclaw.json`, which is generated from an Ansible template.

**Principle of least privilege.** Each service runs as its own Unix user.
Only the Pipelock user can make outbound HTTP/HTTPS connections. Agents
never see API keys. The config file is owned by root and readable (but not
writable) by the agent user.

**Declarative and reproducible.** The entire deployment is expressed as
Ansible roles, Jinja2 templates, and YAML variables. There is no
imperative setup script to run by hand. Running the playbook on a fresh
host produces the same result as running it on an existing one.

---

## Security Layers

The following diagram shows the six layers and how traffic passes through
them. Detailed descriptions follow.

```
                                Internet
                                    |
                        +-----------+-----------+
                        |     nftables (L1)     |   <-- UID-based egress rules
                        +-----------+-----------+
                                    |
                        +-----------+-----------+
                        |   Pipelock proxy (L2) |   <-- domain allowlist, DLP
                        +-----------+-----------+
                                    |
           +------------------------+------------------------+
           |                                                 |
+----------+----------+                          +-----------+-----------+
| LlamaFirewall (L3)  |                          |    Locksmith (L4)     |
| inference scanning   |                          | credential injection  |
+----------+----------+                          +-----------+-----------+
           |                                                 |
           +------------------------+------------------------+
                                    |
                        +-----------+-----------+
                        |  Application (L5)     |   <-- config lockdown,
                        |  openclaw.json        |       tool profiles,
                        +-----------+-----------+       workspace isolation
                                    |
                        +-----------+-----------+
                        |  Container sandbox    |   <-- Docker/gVisor (L6)
                        |  (currently disabled) |
                        +----------+------------+
```

### Layer 1: Network Firewall (nftables)

**Role:** `roles/nftables/`

The firewall enforces a default-drop egress policy. Rules are scoped by
UID so that each service can only reach the network destinations it needs.

Key rules in the output chain:

- The `pipelock` UID is the only identity allowed to make outbound HTTP/HTTPS
  connections to the public internet (non-RFC1918 addresses).
- The `llamafirewall` UID can reach LAN inference endpoints on configured
  ports (443, 11434, 8091 by default). When LlamaFirewall is disabled,
  this access is open to all UIDs.
- The `openclaw` UID can reach Slack IPs directly (the Slack SDK requires
  WebSocket connections that cannot transit an HTTP proxy). Slack IPs are
  resolved by a systemd timer and loaded into an nftables set with a 10-minute
  timeout.
- Docker bridge traffic (172.16.0.0/12 by default) is allowed for container
  sandbox communication and LlamaFirewall's Docker-bridge listener.
- DNS to the configured gateway IP is allowed for all UIDs.
- All other egress is logged with the `nft-egress-block:` prefix and dropped.

The input chain is also default-drop, allowing:
- SSH and the OpenClaw gateway port from management CIDRs.
- Telemetry dashboard ports (Grafana, Prometheus, Phoenix) from management
  CIDRs, when telemetry is enabled.
- Traffic from explicitly listed LAN IPs.

nftables uses its own table (`inet openclaw`) at priority 10 so it does not
interfere with Docker's iptables-nft chains at priority 0.

### Layer 2: Egress Proxy (Pipelock)

**Role:** `roles/pipelock/`

Pipelock is an HTTP/HTTPS forward proxy that all agent internet traffic must
pass through. nftables enforces this -- the `openclaw` user cannot reach the
internet directly.

Capabilities:

| Feature | Description |
|---------|-------------|
| Domain allowlist | Only listed domains (with wildcard support) are reachable. Defaults include AI provider APIs, package registries, and GitHub. |
| Blocklist | Known exfiltration endpoints (pastebin, transfer.sh, ngrok, etc.) are blocked even if they match an allowlist wildcard. |
| CONNECT tunnels | HTTPS traffic uses CONNECT with SNI verification to confirm the TLS handshake matches the requested host. |
| DLP scanning | Outbound bodies are checked for secret patterns (API keys, tokens) and high-entropy strings that may indicate credential leakage. |
| Tool-chain detection | Identifies automated reconnaissance patterns (e.g., rapid sequential requests to different endpoints) and logs warnings. |
| Rate limiting | Configurable `max_requests_per_minute` (default: 60) prevents runaway agents from flooding upstream services. |

The proxy listens on `0.0.0.0:8888` by default. OpenClaw's `HTTP_PROXY` and
`HTTPS_PROXY` environment variables point to this address (via the Docker
bridge IP `172.17.0.1:8888` when sandboxed).

### Layer 3: Inference Firewall (LlamaFirewall)

**Role:** `roles/llamafirewall/`

A FastAPI reverse proxy that sits between OpenClaw and all model providers.
OpenClaw sends inference requests to
`http://<host>:9100/<provider_name>/v1/chat/completions` and the proxy routes
them to the real upstream after scanning.

**Input scanning (PromptGuard 2).** User messages are scanned for prompt
injection using Meta's PromptGuard 2 model (86M parameters, runs locally).
Blocked requests return HTTP 403 with a structured error.

**Output scanning (CodeShield).** Assistant responses are scanned for
unsafe code patterns. Blocked output is replaced with a safe placeholder
message.

**Budget enforcement.** When enabled, the proxy tracks token usage per
provider (supporting both OpenAI and Anthropic usage formats, including
streaming responses) and rejects requests that would exceed a configurable
monthly USD limit. Budget state is persisted to a JSON file and resets
monthly.

**Routing.** Each upstream is classified as `cloud` or `lan`:
- Cloud upstreams are reached through Pipelock (the proxy's httpx client is
  configured with `proxy=PIPELOCK_PROXY`).
- LAN upstreams are reached directly (nftables allows the `llamafirewall`
  UID to reach LAN inference ports).

**Telemetry.** When the telemetry stack is enabled, the proxy exports
OpenTelemetry traces and metrics (request duration, scan duration, token
counts, block counts) to the OTel collector.

### Layer 4: Credential Proxy (Locksmith)

**Role:** `roles/locksmith/`
**Source:** [github.com/SentientSwarm/agent-locksmith](https://github.com/SentientSwarm/agent-locksmith)

A Rust proxy that injects API credentials into upstream requests so the agent
never sees API keys.

How it works:

1. The agent sends a request to `http://localhost:9200/api/<tool>/...` with
   no authentication headers.
2. Locksmith looks up the tool in its configuration, injects the correct
   `Authorization` header (or other auth header), and forwards the request
   to the real upstream.
3. Cloud tool traffic is routed through Pipelock. Local tool traffic goes
   direct.
4. Auth-related headers are stripped from the response before returning it
   to the agent.

The agent can discover available tools via `GET /tools`, which returns tool
names and descriptions without exposing credentials.

Secrets are handled with `secrecy::SecretString` in Rust, meaning they are
zeroized in memory on drop and never appear in debug output or logs.

Locksmith's configuration is generated from Ansible variables. API keys are
stored in Ansible Vault and injected into the systemd service as environment
variables -- they never appear in the on-disk config file.

### Layer 5: Application Hardening

**Role:** `roles/openclaw_config/`

This layer hardens OpenClaw's own configuration without modifying its source
code.

**Config file ownership.** `openclaw.json` is owned by `root:openclaw` with
mode `0640`. The `openclaw` user can read it to start the gateway, but
cannot modify it. This prevents an agent from changing its own model
configuration, disabling security features, or adding new tool permissions.

**Tools profile.** The `tools_profile` setting (default: `messaging`)
controls which tool categories the agent can use (exec, read, write, fetch,
etc.). This limits the blast radius if an agent is compromised.

**Denied commands.** A configurable list of commands (camera, contacts,
calendar, SMS, etc.) is blocked at the gateway level regardless of tool
profile.

**Proxy environment.** `HTTP_PROXY` and `HTTPS_PROXY` are baked into the
config, ensuring all fetch operations go through Pipelock. `NO_PROXY`
excludes localhost and configured LAN IPs so local services are reached
directly.

**Per-agent workspaces.** Each agent definition in `openclaw_agents` gets
its own workspace directory under `/home/openclaw/.openclaw/agents/<id>/`.
Agents cannot access each other's workspaces.

**Memory search.** When enabled, agents use local embeddings via Ollama
rather than sending memory content to cloud services. The Ollama instance
runs as a separate `ollama` user on port 11434.

### Layer 6: Container Sandbox (currently disabled)

**Role:** `roles/docker_hardening/`

Docker-based isolation for agent tool calls using gVisor (`runsc`) as the
default runtime.

When enabled, containers run with:
- Read-only root filesystem
- 2 GB memory limit (configurable)
- 2 CPU limit (configurable)
- 256 PID limit (configurable)
- `no-new-privileges` flag
- Log rotation (10 MB max, 3 files)

**Current status:** Disabled. OpenClaw's sandbox path checker blocks reads
to its own installation directory (built-in skills, documentation), which
prevents normal operation. The sandbox will be re-enabled when OpenClaw adds
an `allowedReadPaths` configuration option.

**Mitigations while disabled:** The other five layers remain active. Config
lockdown prevents the agent from modifying its own configuration. nftables
prevents direct internet access. Tool profile restrictions limit available
operations.

---

## Data Flow

### Outbound request (agent fetches a URL)

```
Agent process (openclaw user)
  |
  | HTTP_PROXY=http://172.17.0.1:8888
  v
Pipelock (port 8888, pipelock user)
  |-- Domain allowlist check -----> BLOCK if domain not listed
  |-- DLP scan (secrets/entropy) -> BLOCK if leak detected
  |-- Rate limit check -----------> BLOCK if over limit
  |
  | CONNECT tunnel with SNI verification
  v
Destination (e.g., api.github.com)
  |
  v
Response returned to agent
```

nftables ensures the `openclaw` user cannot bypass the proxy. Any direct
outbound HTTP/HTTPS from a non-`pipelock` UID is dropped and logged.

### Inference request (agent calls a model)

```
Agent process
  |
  | POST http://172.17.0.1:9100/<provider>/v1/chat/completions
  v
LlamaFirewall proxy (port 9100, llamafirewall user)
  |-- PromptGuard 2 input scan ---> BLOCK (403) if injection detected
  |-- Budget check (optional) ----> BLOCK (429) if budget exceeded
  |
  |-- Cloud upstream:               LAN upstream:
  |     via Pipelock -> internet     direct to Kamiwaza/Ollama
  v
Upstream model endpoint
  |
  v
Response
  |-- CodeShield output scan -----> REPLACE content if unsafe code detected
  |-- Token usage recorded for budget tracking
  v
Response returned to agent
```

### Inbound message (Slack or Telegram)

```
Slack (Socket Mode) / Telegram (long-polling)
  |
  v
OpenClaw gateway (port 18789, openclaw user)
  |-- Agent binding routes message to correct agent identity
  |-- Session created or resumed
  v
Agent processes message using configured model
  (inference goes through LlamaFirewall flow above)
```

Slack uses Socket Mode (outbound WebSocket), so no inbound port is needed
for Slack. The `openclaw` user is allowed direct outbound access to Slack
IPs via a dedicated nftables rule with a DNS-refreshed IP set. Telegram uses
long-polling (also outbound-initiated), routed through Pipelock.

### Tool call (agent uses GitHub, Tavily, etc.)

```
Agent process
  |
  | GET http://localhost:9200/api/github/repos
  | (no Authorization header)
  v
Locksmith (port 9200, openclaw user)
  |-- Injects Authorization: Bearer <real-token>
  |-- Cloud tools: forwards through Pipelock
  |-- Local tools: forwards directly
  v
Upstream API (e.g., api.github.com)
  |
  v
Response
  |-- Auth headers stripped
  v
Response returned to agent (no credentials exposed)
```

---

## Service Map

```
+------------------------------------------------------------------+
|  Host                                                            |
|                                                                  |
|  +------------------+    +------------------+                    |
|  | OpenClaw gateway |    | Locksmith        |                    |
|  | user: openclaw   |    | user: openclaw   |                    |
|  | port: 18789      |    | port: 9200       |                    |
|  +--------+---------+    +--------+---------+                    |
|           |                       |                              |
|  +--------+---------+    +--------+---------+                    |
|  | LlamaFirewall    |    | Ollama           |                    |
|  | user: llamafw    |    | user: ollama     |                    |
|  | port: 9100       |    | port: 11434      |                    |
|  +--------+---------+    +------------------+                    |
|           |                                                      |
|  +--------+---------+                                            |
|  | Pipelock         |                                            |
|  | user: pipelock   |                                            |
|  | port: 8888       |                                            |
|  +--------+---------+                                            |
|           |                                                      |
|  +--------+---------+    +------------------+                    |
|  | nftables         |    | Docker (gVisor)  |                    |
|  | user: root       |    | user: root       |                    |
|  +------------------+    +------------------+                    |
+------------------------------------------------------------------+
```

| Service | User | Port | Purpose |
|---------|------|------|---------|
| OpenClaw | `openclaw` | 18789 | AI agent gateway |
| Pipelock | `pipelock` | 8888 | Egress proxy with domain allowlist and DLP |
| LlamaFirewall | `llamafirewall` | 9100 | Inference proxy with prompt/code scanning |
| Locksmith | `openclaw` | 9200 | Credential injection proxy |
| Ollama | `ollama` | 11434 | Local embedding models for memory search |
| Docker | `root` | -- | Container runtime (gVisor default) |
| nftables | `root` | -- | Network firewall (UID-based egress control) |

---

## Deployment Phases

The playbook (`playbook.yml`) is organized into phases that can be run
independently via Ansible tags.

```
Phase 1 (bootstrap)     System prep: create users, install Docker,
                         install Node.js, fetch OpenClaw binary.

Phase 2 (phase2)         Hardening layers:
                           - docker_hardening: gVisor, daemon config
                           - pipelock: egress proxy + DLP
                           - locksmith: credential proxy (optional)
                           - nftables: firewall rules
                           - llamafirewall: inference proxy (optional)

Phase 2b (telemetry)     Observability stack (optional):
                           - otel_collector, phoenix, loki,
                             prometheus, grafana, caddy

Phase 2c (ollama)        Local embeddings (optional):
                           - Ollama with configured models

Phase 3 (phase3)         OpenClaw configuration:
                           - openclaw_onboard: initial setup
                           - openclaw_config: generate openclaw.json
                           - openclaw_service: systemd unit
                           - agent_state: clone repos, link workspaces

Verify (verify)          Post-deployment posture check:
                           - Runs verify-posture.sh
                           - Fails the play if NON-COMPLIANT
```

A typical deployment runs all phases:

```
ansible-playbook playbook.yml --ask-become-pass --ask-vault-pass
```

Subsequent updates can target specific phases:

```
ansible-playbook playbook.yml --tags phase2,phase3 --ask-become-pass
```

---

## Three-Repo Model

The deployment is split across three repositories with distinct visibility
and ownership.

```
+------------------------------------+     +----------------------------------+
| openclaw-hardened (public)         |     | your-org/openclaw-hardened-site   |
|                                    |     | (private)                        |
| - playbook.yml                     |     |                                  |
| - roles/                           |     | - run.sh                         |
| - examples/                        |     | - site.cfg                       |
| - docs/                            |     | - inventory/hosts.yml            |
|                                    |     | - group_vars/                    |
| No IPs, no keys, no agent defs.   |     |   - main.yml (network, agents)   |
|                                    |     |   - vault.yml (encrypted)        |
+------------------------------------+     +----------------------------------+
                    |                                      |
                    |      references via site.cfg         |
                    +<-------------------------------------+
                    |
                    |      +----------------------------------+
                    |      | your-org/openclaw-agents          |
                    |      | (private)                        |
                    |      |                                  |
                    |      | - shared/knowledge/              |
                    |      | - agents/alice/workspace/         |
                    |      | - agents/alice/memory/dumps/      |
                    |      +----------------------------------+
                    |                      |
                    |  cloned to host by   |
                    |  agent_state role    |
                    +<---------------------+
```

| Repo | Visibility | Contains |
|------|-----------|----------|
| `SentientSwarm/openclaw-hardened` | Public | Ansible roles, playbook, templates, examples, docs |
| `your-org/openclaw-hardened-site` | Private | Inventory, group_vars, vault, `site.cfg`, `run.sh` |
| `your-org/openclaw-agents` | Private | Agent workspaces, memory databases, skills, shared knowledge |

**The site repo is the deployment entry point.** Its `run.sh` script reads
`site.cfg` to locate the platform repo, sets `ANSIBLE_ROLES_PATH`, and
invokes `ansible-playbook` with the site inventory. This means:

- The public repo contains no site-specific values (IPs, tokens, agent
  definitions).
- The private repo contains no Ansible logic (roles, templates, handlers).
- Upgrading the platform is a `git pull` or `git checkout <tag>` in the
  platform repo, followed by re-running `run.sh`.

The agents repo is cloned to the target host by the `agent_state` role.
Each agent's workspace directory is symlinked into the OpenClaw data
directory. Shared knowledge files are symlinked into a common path that
all agents can access.

---

## Configuration Layering

Ansible variables follow a three-tier hierarchy:

```
Role defaults (roles/*/defaults/main.yml)
  |
  v  overridden by
Site config (group_vars/agent_hosts/main.yml)
  |
  v  overridden by
Host vars (host_vars/<hostname>.yml)
```

Role defaults provide sensible values for any deployment (port numbers,
timeouts, default allowlists). Site config provides deployment-specific
values (network topology, inference endpoints, agent definitions, feature
flags). Host vars provide per-host overrides (channel bot tokens, host IP).

The playbook's `pre_tasks` deep-merge role defaults with site overrides
using Ansible's `combine(recursive=True)` filter, so site config only needs
to specify the keys it wants to change.

**Principle:** If a value contains an IP address, hostname, UUID, or vault
reference, it belongs in site config. Everything else is a role default.

---

## Telemetry Stack (optional)

When `telemetry.enabled: true`, the following services are deployed:

```
OpenClaw ──> OTel Collector ──> Phoenix (traces)
                            ──> Loki (logs)
                            ──> Prometheus (metrics)
                                     |
                                  Grafana (dashboards)
                                     |
                                  Caddy (HTTPS reverse proxy)
```

- **Phoenix** provides trace visualization for LLM interactions.
- **Prometheus** scrapes metrics from all services.
- **Grafana** provides dashboards, accessed through Caddy with TLS.
- **Loki** collects structured logs.
- **Caddy** terminates TLS and reverse-proxies to each dashboard, restricted
  to management CIDRs by nftables.

Both OpenClaw and LlamaFirewall export OpenTelemetry spans and metrics.
LlamaFirewall exports per-provider request duration, scan duration, token
counts, and block counts.

---

## Verification

The `verify` role runs at the end of every deployment. It deploys a shell
script (`verify-posture.sh`) that checks:

- Service users exist and have correct group membership.
- Systemd services are running (OpenClaw, Pipelock, LlamaFirewall, etc.).
- nftables rules are loaded in the `inet openclaw` table.
- Config file permissions are correct (root-owned, group-readable).
- Docker daemon is configured with the expected runtime.
- Pipelock is responding on its listen port.

If any check produces a `NON-COMPLIANT` result, the playbook fails (unless
`verify_ignore_failures` is set). This provides a machine-verifiable gate
that the security posture is intact after every deployment.
