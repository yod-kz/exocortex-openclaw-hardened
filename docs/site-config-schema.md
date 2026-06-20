# Site Configuration Schema

All variables for a site deployment, defined in
`group_vars/agent_hosts/main.yml` unless otherwise noted. Role defaults
live in `roles/<role>/defaults/main.yml` and are overridden by site config.

> **Important:** Ansible uses shallow dict merge. If you override **any** key
> in a dict (e.g. `pipelock`), you must include the **entire** dict in your
> site config. Role defaults only apply when the top-level dict is completely
> absent from site config.

**See also:**
[Architecture](architecture.md) |
[Host-Side Pipelock and Locksmith](host-side-pipelock-locksmith.md) |
[Installation](installation.md) |
[Operations](operations.md) |
[Security](security.md) |
[Site Repo Layout](reference/site-repo-layout.md) |
[Agents Repo Layout](reference/agents-repo-layout.md)

---

## Global Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `openclaw_version` | string | `latest` | Pinned OpenClaw version (e.g. `2026.3.12`). Set to `latest` to skip version management. |

---

## Required Variables

### network

| Variable | Type | Description |
|----------|------|-------------|
| `network.gateway_ip` | string | Default gateway / DNS server IP |
| `network.dns_server` | string | DNS server IP (usually same as gateway) |
| `network.subnet` | CIDR string | LAN subnet (e.g. `192.168.50.0/24`) |
| `network.allowed_lan_ips` | list of `{ip, comment}` | IPs reachable from agent hosts; all others blocked |
| `network.mgmt_cidrs` | list of `{cidr, comment}` | CIDRs allowed SSH and UI access |
| `network.inference_ports` | list of int | Ports opened to inference hosts in nftables (default: `[443, 11434, 8091]`) |
| `network.docker_cidr` | CIDR string | Docker bridge CIDR, must match `daemon.json` (default: `172.16.0.0/12`) |

### inference

| Variable | Type | Description |
|----------|------|-------------|
| `inference.endpoints` | list of endpoint objects | Model provider configurations (see below) |

#### Endpoint fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `provider_name` | string | yes | Unique slug; used as URL path prefix in LlamaFirewall routing |
| `host_alias` | string | yes | Friendly name for the inference host |
| `base_url` | string | yes | Upstream API base URL |
| `api_type` | string | yes | `openai-completions` or `anthropic` |
| `model_id` | string | yes | Model identifier sent to the upstream |
| `model_name` | string | yes | Human-readable model name |
| `context_window` | int | yes | Maximum context window (tokens) |
| `max_tokens` | int | yes | Maximum output tokens |
| `reasoning` | bool | yes | Whether the model supports extended reasoning |
| `primary` | bool | yes | Mark one endpoint as the default model |
| `tls_skip_verify` | bool | yes | Skip TLS certificate verification for self-signed certs |
| `location` | string | no | `cloud` for cloud endpoints; omit for LAN |
| `api_key` | string | no | API key (use vault reference); required for cloud endpoints |
| `api_key_header` | string | no | Header name for the key (e.g. `Authorization`, `x-api-key`) |
| `api_key_prefix` | string | no | Prefix before the key value (e.g. `Bearer`); empty string for none |
| `cost_per_1m_input_tokens` | float | no | USD per 1M input tokens (required for budget tracking) |
| `cost_per_1m_output_tokens` | float | no | USD per 1M output tokens (required for budget tracking) |
| `budget_monthly_usd` | float | no | Per-provider monthly spend cap (overrides `llamafirewall.budget.default_monthly_usd`) |

### verify

| Variable | Type | Description |
|----------|------|-------------|
| `verify.inference_endpoints` | list of endpoint check objects | Endpoints tested during deployment verification |

#### Endpoint check fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Display name |
| `url` | string | yes | URL to probe |
| `skip_tls` | bool | no | Skip TLS verification |
| `cloud` | bool | no | Endpoint is cloud-hosted (route via Pipelock) |
| `requires_key` | string | no | Vault variable name that must be set |

---

## Optional Variables (override role defaults)

### pipelock

Egress-filtering forward proxy. All external traffic routes through Pipelock.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `pipelock.version` | string | `latest` | Container image tag |
| `pipelock.listen` | string | `0.0.0.0:8888` | Listen address:port |
| `pipelock.mode` | string | `balanced` | Policy mode: `balanced`, `strict`, or `audit` |
| `pipelock.enforce` | bool | `true` | Enforce policy (vs. log-only) |
| `pipelock.api_allowlist` | list of string | *(see role default)* | Allowed destination globs (merged with `api_allowlist_extra`) |
| `pipelock.api_allowlist_extra` | list of string | `[]` | Additional allowed destinations appended to the base allowlist |
| `pipelock.blocklist` | list of string | *(see role default)* | Explicitly blocked destination globs |
| `pipelock.dlp.scan_env` | bool | `false` | Scan environment variables for secrets |
| `pipelock.dlp.secret_patterns` | bool | `true` | Detect secret patterns in outbound traffic |
| `pipelock.dlp.entropy_analysis` | bool | `true` | Entropy-based secret detection |
| `pipelock.tool_chain_detection.enabled` | bool | `true` | Detect tool-chain exfiltration patterns |
| `pipelock.tool_chain_detection.action` | string | `warn` | Action on detection: `warn` or `block` |
| `pipelock.tool_chain_detection.window_size` | int | `20` | Number of requests in detection window |
| `pipelock.tool_chain_detection.window_seconds` | int | `300` | Detection window duration (seconds) |
| `pipelock.tool_chain_detection.max_gap` | int | `3` | Maximum gap between chain steps |
| `pipelock.monitoring.entropy_threshold` | float | `4.5` | Shannon entropy threshold for alerts |
| `pipelock.monitoring.max_url_length` | int | `2048` | Maximum allowed URL length |
| `pipelock.monitoring.max_requests_per_minute` | int | `60` | Rate limit per source |

### locksmith

Credential-injecting reverse proxy for tool APIs.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `locksmith.enabled` | bool | `true` | Enable Locksmith. Hardened defaults treat it as part of the base boundary |
| `locksmith.install_method` | string | `auto` | Install mode: `auto`, `release`, `source`, or `existing` |
| `locksmith.version` | string | `latest` | Release tag when release download is used |
| `locksmith.daemon_binary_path` | string | `/usr/local/bin/locksmithd` | Daemon binary used by systemd |
| `locksmith.cli_binary_path` | string | `/usr/local/bin/locksmith` | Operator/agent CLI binary |
| `locksmith.source_dir` | string | `{{ playbook_dir }}/../exocortex-agent-locksmith` | Local source checkout used by `auto` fallback or `source` install |
| `locksmith.listen_host` | string | `127.0.0.1` | Bind address |
| `locksmith.listen_port` | int | `9200` | Listen port |
| `locksmith.log_level` | string | `info` | Log level |
| `locksmith.inbound_token` | string | `""` | Bearer token agents must present (vault reference) |
| `locksmith.oauth_sealing_key` | string | `""` | Optional base64 32-byte OAuth sealing key rendered as `LOCKSMITH_OAUTH_SEALING_KEY` |
| `locksmith.env_files` | list | `[]` | Optional root-readable environment files sourced by `locksmith.service` after `/etc/locksmith/locksmith.env` |
| `locksmith.required` | bool | `true` | Render OpenClaw's Locksmith plugin in required mode |
| `locksmith.generic_tool` | bool | `false` | Expose the generic `locksmith_call` tool when true; hardened deployments should keep this false |
| `locksmith.openclaw_base_url` | string | derived from listen host/port | URL rendered into OpenClaw plugin config |
| `locksmith.slack_native.enabled` | bool | `true` | Enable generated Locksmith credential transport tools for OpenClaw native Slack accounts |
| `locksmith.slack_native.bot_token_env` | string | `SLACK_BOT_TOKEN` | Env var containing the real xoxb bot token for `/transport/slack-bot` |
| `locksmith.slack_native.app_token_env` | string | `SLACK_APP_TOKEN` | Env var containing the real xapp Socket Mode token for `/transport/slack-app` |
| `locksmith.slack_native.user_token_env` | string | `SLACK_USER_TOKEN` | Env var containing an optional real xoxp user token for `/transport/slack-user` |
| `locksmith.slack_native.bot_token` | string | `""` | Optional vault-managed xoxb token rendered only into Locksmith's env file |
| `locksmith.slack_native.app_token` | string | `""` | Optional vault-managed xapp Socket Mode token rendered only into Locksmith's env file |
| `locksmith.slack_native.user_token` | string | `""` | Optional vault-managed xoxp token rendered only into Locksmith's env file |
| `locksmith.slack_native.include_user` | bool | `false` | Also generate fake xoxp handles for native Slack accounts |
| `locksmith.kamiwaza.enabled` | bool | `false` | Enable Locksmith's Kamiwaza MCP provider |
| `locksmith.kamiwaza.api_url` | string | `""` | Kamiwaza platform API base, for example `https://localhost/api`; if empty, Locksmith tries Kamiwaza env vars and built-in local candidates |
| `locksmith.kamiwaza.api_token` | string | `""` | Kamiwaza PAT or service token; rendered only into Locksmith's root-owned environment |
| `locksmith.kamiwaza.api_token_env` | string | `KAMIWAZA_API_KEY` | Environment variable referenced by Locksmith config |
| `locksmith.kamiwaza.api_token_from_env` | bool | `false` | Render the `api_token` reference even when the token is supplied by an external env file |
| `locksmith.kamiwaza.verify_tls` | bool | `true` | Verify Kamiwaza TLS; set false only for local self-signed dev installs |
| `locksmith.kamiwaza.projected_tools` | list | `[]` | Optional OpenClaw projected tool definitions for discovered Kamiwaza MCP slugs |
| `locksmith.tools` | list of tool objects | `[]` | Tool definitions (see below) |

#### Locksmith tool fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Tool slug (URL path component) |
| `description` | string | yes | Human-readable description |
| `upstream` | string | yes | Upstream base URL |
| `egress` | string | yes | `proxied` for Pipelock CONNECT routing, `direct` for local/LAN services |
| `api_key` | string | yes | Credential to inject (vault reference) |
| `api_key_header` | string | yes | Header name for the credential |
| `api_key_prefix` | string | yes | Prefix before key value (empty string for none) |
| `auth_required` | bool | no | Set false only for intentionally unauthenticated tools; defaults to true |
| `api_key_env` | string | no | Environment variable name exposed to containers |
| `api_key_from_env` | bool | no | Render the credential env reference even when `api_key` is supplied by an external env file |
| `force_replace` | bool | no | When true, Locksmith strips any caller-supplied auth header and fails closed if the replacement credential is unavailable |
| `credential_handles` | list | no | Fake bearer handles accepted by Locksmith `/transport/<tool>/...` routes for SDK credential transport |
| `timeouts.request_seconds` | int | no | Total request timeout |
| `timeouts.idle_seconds` | int | no | Per-read idle timeout for streaming responses |
| `body_limit_bytes` | int | no | Maximum request body size Locksmith accepts for the tool |
| `response.max_size_bytes` | int | no | Optional response size cap |
| `response.content_type_allowlist` | list | no | Optional accepted upstream content types |
| `response.redaction_patterns` | list | no | Optional non-streaming response regex redactions |
| `projected` | bool | no | Project this tool into OpenClaw as `locksmith_<name>`; defaults to true |
| `mode` | string | no | OpenClaw projection mode: `proxy` for HTTP-shaped params or `json` to forward raw tool params as a JSON body |
| `parameters` | object | no | Optional OpenClaw tool parameter schema, useful with `mode: json` |

`cloud` and `timeout_seconds` are still accepted in site config for older deployments, but the role renders Locksmith's v2 shape into `/etc/locksmith/config.yaml`.

#### Kamiwaza projected tool fields

`locksmith.kamiwaza.projected_tools` is an OpenClaw projection allowlist. Locksmith still discovers the live MCP tool from Kamiwaza and injects the bearer token; this list only decides which slugs become first-class OpenClaw tools.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `slug` | string | yes | Locksmith slug, usually `kamiwaza_<extension>_<tool>` after non-alphanumeric characters are normalized to underscores |
| `description` | string | no | Tool description shown to the agent |
| `label` | string | no | Optional display label |
| `mode` | string | no | Defaults to `json`, forwarding raw OpenClaw tool params to Locksmith |
| `method` | string | no | Defaults to `POST` for `json` mode |
| `parameters` | object | no | Optional OpenClaw tool parameter schema copied from MCP `inputSchema` or hand-written |

### host_boundary

Host-owned gateway/untrusted VM boundary. These variables live under
`group_vars/host_boundary/main.yml` and are consumed by
`playbook-host-boundary.yml`, not the standard Linux agent-host playbook.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `host_boundary.enabled` | bool | `false` | Enable host-side boundary changes |
| `host_boundary.platform` | string | `darwin_pf` | Host firewall/service platform; currently macOS PF + launchd |
| `host_boundary.allow_wildcard_service_bind_without_pf` | bool | `false` | Permit unsafe host service wildcard binds without PF; keep false outside throwaway experiments |
| `host_boundary.lima.manage` | bool | `false` | Render and start Lima VMs from this role |
| `host_boundary.lima.recreate` | bool | `false` | Delete and recreate managed VMs |
| `host_boundary.lima.gateway_instance` | string | `openclaw-gateway` | Trusted gateway VM name |
| `host_boundary.lima.untrusted_instance` | string | `openclaw-untrusted` | Untrusted worker VM name |
| `host_boundary.vm_ips.gateway` | string | `""` | Override gateway VM source IP; blank means discover with `limactl shell` |
| `host_boundary.vm_ips.untrusted` | string | `""` | Override untrusted VM source IP; blank means discover with `limactl shell` |
| `host_boundary.vm_ips.extra_direct_egress_sources` | list of string | `[]` | Additional VM/NAT source IPs to block from direct egress without granting service access |
| `host_boundary.pipelock.listen` | string | `0.0.0.0:8888` | Host Pipelock listen address for VM access |
| `host_boundary.locksmith.daemon_binary_path` | string | `/usr/local/bin/locksmithd` | Host Locksmith daemon binary executed by launchd |
| `host_boundary.locksmith.cli_binary_path` | string | `/usr/local/bin/locksmith` | Host Locksmith CLI binary used for operator workflows |
| `host_boundary.locksmith.env_files` | list of string | `[/usr/local/etc/openclaw-boundary/kamiwaza.env]` | Root-only env files sourced by the Locksmith wrapper before daemon start |
| `host_boundary.locksmith.listen_host` | string | `127.0.0.1` | Host Locksmith bind address. Default keeps Locksmith loopback-only behind the bridge |
| `host_boundary.locksmith.listen_port` | int | `9201` | Host Locksmith private loopback port |
| `host_boundary.locksmith.bridge.enabled` | bool | `true` | Expose a PF-gated VM-facing Locksmith port through `socat` |
| `host_boundary.locksmith.bridge.binary_path` | string | `/usr/local/bin/socat` | Bridge binary path |
| `host_boundary.locksmith.bridge.listen_host` | string | `0.0.0.0` | Bridge bind address. PF restricts source access |
| `host_boundary.locksmith.bridge.listen_port` | int | `9200` | VM-facing Locksmith port |
| `host_boundary.locksmith.bridge.target_host` | string | `127.0.0.1` | Bridge target host |
| `host_boundary.locksmith.bridge.target_port` | int | `9201` | Bridge target port |
| `host_boundary.pf.anchor_name` | string | `openclaw-host-boundary` | PF anchor name |
| `host_boundary.pf.cleanup_legacy_anchors` | bool | `true` | Remove older OpenClaw PF anchors that can shadow host-boundary rules |
| `host_boundary.pf.task_transport_host_ports` | list of int | `[]` | Host-forwarded ports that gateway may use for task dispatch, such as untrusted SSH |
| `host_boundary.pf.auto_allow_untrusted_ssh` | bool | `false` | When task transport ports are empty, discover the untrusted Lima SSHLocalPort and allow gateway access to it |
| `host_boundary.application_firewall.allow_listener_binaries` | bool | `true` | Add managed host listener binaries to the macOS Application Firewall allowlist |
| `host_boundary.verify.enabled` | bool | `true` | Run positive and negative boundary checks after install |
| `host_boundary.verify.guest_host_alias` | string | `192.168.64.1` | Host address guests use for verified Pipelock/Locksmith access; prefer the bridge address over `host.lima.internal` when PF must distinguish VMs |

### llamafirewall

LLM safety proxy (prompt injection, code analysis, budget enforcement).

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `llamafirewall.enabled` | bool | `false` | Enable LlamaFirewall proxy |
| `llamafirewall.listen_host` | string | `0.0.0.0` | Bind address |
| `llamafirewall.listen_port` | int | `9100` | Listen port |
| `llamafirewall.connect_host` | string | `172.17.0.1` | Address containers use to reach the proxy (Docker bridge gateway) |
| `llamafirewall.promptguard.enabled` | bool | `true` | Enable PromptGuard 2 prompt injection detection |
| `llamafirewall.promptguard.model` | string | `meta-llama/Prompt-Guard-2-86M` | HuggingFace model ID for PromptGuard |
| `llamafirewall.codeshield.enabled` | bool | `true` | Enable CodeShield (Semgrep-based code analysis) |
| `llamafirewall.alignmentcheck.enabled` | bool | `false` | Enable AlignmentCheck (LLM-as-judge; requires a second LLM) |
| `llamafirewall.budget.enabled` | bool | `true` | Enable per-provider monthly budget enforcement |
| `llamafirewall.budget.default_monthly_usd` | float | `50.00` | Default per-provider monthly spend cap (USD) |
| `llamafirewall.budget.state_file` | string | `/var/lib/llamafirewall/budget.json` | Path to budget state file |
| `llamafirewall.venv_path` | string | `/opt/llamafirewall/venv` | Python virtualenv path |
| `llamafirewall.app_path` | string | `/opt/llamafirewall` | Application install path |

### openclaw

Core OpenClaw gateway and agent runtime settings.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `openclaw.install_mode` | string | `release` | Install mode: `release` (pnpm) or `development` (git clone + build) |
| `openclaw.gateway_bind` | string | `lan` | Gateway bind mode (`lan` or `0.0.0.0`) |
| `openclaw.gateway_port` | int | `18789` | Gateway listen port |
| `openclaw.gateway_auth_mode` | string | `password` | Auth mode: `password` or `token` |
| `openclaw.sandbox.mode` | string | `non-main` | Sandbox mode — see [Sandbox Modes](#sandbox-modes) below |
| `openclaw.sandbox.docker_network` | string | `bridge` | Docker network for sandboxed containers |
| `openclaw.sandbox.read_only_root` | bool | `true` | Mount container root filesystem read-only |
| `openclaw.sandbox.memory` | string | `2g` | Container memory limit |
| `openclaw.sandbox.cpus` | int | `2` | Container CPU limit |
| `openclaw.sandbox.pids_limit` | int | `256` | Container PID limit |

### openclaw_agents

Each entry in `openclaw_agents` renders to `agents.list[]` in OpenClaw config.
Common fields are `id`, `name`, `default`, `workspace_subdir`, `model`,
`models`, `memory_search`, `skills`, `state_repo`, and `state_path`.

For hardened gateway/untrusted layouts, the config renderer also passes through
these optional OpenClaw-native blocks without interpreting them:

| Field | Type | Description |
|-------|------|-------------|
| `tools` | object | Per-agent tool allow/deny policy, filesystem policy, and execution policy |
| `subagents` | object | Per-agent subagent routing and allowlist settings |
| `sandbox` | object | Per-agent sandbox backend/settings such as SSH untrusted worker targets |

This keeps policy in config and the Locksmith plugin instead of requiring
OpenClaw core patches.

These blocks are trusted deployment policy. Review them the same way as
firewall or credential config: a broad `tools`, `subagents`, or `sandbox`
override can intentionally expand an agent's authority. The role passes them
through to avoid fork-only OpenClaw core patches; it does not attempt to
re-implement OpenClaw's policy schema in Ansible.

### openclaw_bindings

Additional OpenClaw route or ACP bindings appended after the automatically
generated per-agent channel account bindings. Use this when one channel account
should route different peers to different agents, for example one Slack Socket
Mode app where Matt's DM routes to a private agent and wildcard DMs route to a
public constrained agent.

Example:

```yaml
openclaw_bindings:
  - type: "route"
    agentId: "matt"
    match:
      channel: "slack"
      accountId: "public"
      peer:
        kind: "direct"
        id: "U06AEGM6QS2"
    session:
      dmScope: "per-channel-peer"
```

OpenClaw route matching supports `peer.id: "*"` for wildcard peers. Exact peer
bindings win over wildcard/account fallback bindings.

#### Sandbox Modes

The sandbox controls whether agent tool calls (exec, file read/write, fetch) run
inside isolated Docker containers or directly on the host.

| Mode | Behaviour | Use case |
|------|-----------|----------|
| `non-main` | Sandboxes all non-main sessions (Slack, Telegram) | Default — strongest isolation for messaging channels |
| `main-only` | Sandboxes only the gateway UI sessions | Lighter — trusts messaging channels, isolates web UI |
| `off` | No sandbox — tool calls run directly as the `openclaw` user | Weakest isolation, but no path restrictions |

**Current recommendation: `off` with config lockdown.**

OpenClaw's sandbox path check blocks reads to any path outside the sandbox root
directory. This prevents agents from accessing the platform's own built-in
skills and documentation (installed under `~/.local/share/pnpm/...`), which
causes agents to fail on basic research and skill-loading operations. There is
currently no `allowedReadPaths` option to extend the sandbox root.

Until OpenClaw adds support for mounting the install directory into the sandbox,
set `sandbox.mode: "off"` and rely on the platform's other security layers:

| Layer | Protection | Active when sandbox is off? |
|-------|------------|---------------------------|
| **nftables** | Blocks direct internet egress; only Pipelock can reach external hosts | Yes |
| **Pipelock** | HTTPS proxy with domain allowlist, DLP scanning, rate limiting | Yes |
| **LlamaFirewall** | Scans inference requests for prompt injection and policy violations | Yes |
| **Unix permissions** | Agents run as `openclaw` user with limited system access | Yes |
| **Config lockdown** | `openclaw.json` owned by `root:openclaw` mode `0640` — agents can read but not modify | Yes |
| **OpenClaw tool allowlist** | `tools.profile` controls which tools are available | Yes |

**What you lose with sandbox off:**

- Filesystem isolation — agents can read/write anything the `openclaw` user can
  access, including other agents' workspaces and memory
- Resource limits — no memory/CPU/PID caps on tool execution
- Network isolation — tool calls use the host network (still constrained by
  nftables + Pipelock)

**Mitigations applied:**

- `openclaw.json` is deployed as `root:openclaw 0640` so agents cannot modify
  their own configuration, proxy settings, or tool restrictions
- nftables ensures all HTTP/HTTPS traffic must go through Pipelock regardless
  of proxy environment variables — removing or changing `HTTP_PROXY` causes
  requests to be dropped, not to bypass the proxy
| `openclaw.tools_profile` | string | `messaging` | Tools profile to activate |
| `openclaw.fetch_proxy` | string | `http://172.17.0.1:8888` | HTTP(S) proxy for containers (Pipelock via Docker bridge) |
| `openclaw.no_proxy_extra` | list of string | *(undefined)* | Additional hosts to bypass the proxy |
| `openclaw.max_concurrent` | int | `4` | Max concurrent agent tasks |
| `openclaw.subagent_max_concurrent` | int | `8` | Max concurrent sub-agent tasks |
| `openclaw.compaction_mode` | string | `safeguard` | Context compaction mode |
| `openclaw.control_ui_origins` | list of string | *(none)* | Allowed origins for the control UI (CORS) |
| `openclaw.deny_commands` | list of string | *(see role default)* | Gateway commands that are blocked |
| `openclaw_binary` | string | `/home/openclaw/.local/bin/openclaw` | Path to the OpenClaw binary |

### docker

Docker / gVisor hardening settings.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `docker.default_runtime` | string | `runsc` | Default OCI runtime (`runsc` for gVisor) |
| `docker.no_new_privileges` | bool | `true` | Set `no-new-privileges` security option |
| `docker.log_max_size` | string | `10m` | Max size per log file |
| `docker.log_max_file` | string | `3` | Max number of rotated log files |

### ollama

Local embedding model server for memory search. Disabled by default.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `ollama.enabled` | bool | `false` | Enable Ollama installation and service |
| `ollama.embedding_model` | string | `nomic-embed-text` | Embedding model to pull (any Ollama-compatible model) |
| `ollama.host` | string | `127.0.0.1` | Bind address (localhost only — accessed by OpenClaw on same host) |
| `ollama.port` | int | `11434` | Listen port |

When enabled, the `openclaw_config` template sets `memorySearch.provider: "ollama"`
for agents with `memory_search: true`. Model pulls use a temporary nftables
egress rule (same pattern as OpenClaw upgrades).

### openclaw_memory

Native OpenClaw memory stack. Disabled by default. When enabled, the renderer can
emit top-level `memory.qmd`, `plugins.entries.active-memory`, and
`plugins.entries.memory-core.config.dreaming`.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `openclaw_memory.enabled` | bool | `false` | Default per-agent memory posture; agents can override with `openclaw_agents[].memory.enabled` |
| `openclaw_memory.qmd.enabled` | bool | `false` | Render OpenClaw `memory.backend: "qmd"` and `memory.qmd` |
| `openclaw_memory.qmd.search_mode` | string | `search` | QMD search mode: `search`, `vsearch`, or `query` |
| `openclaw_memory.qmd.include_default_memory` | bool | `true` | Index `MEMORY.md` and `memory/**/*.md` |
| `openclaw_memory.qmd.sessions.enabled` | bool | `false` | Index session transcripts |
| `openclaw_memory.qmd.scope` | object | direct-only | OpenClaw session policy controlling where QMD results can surface |
| `openclaw_memory.active_memory.enabled` | bool | `false` | Enable the bundled `active-memory` plugin |
| `openclaw_memory.active_memory.agents` | list | `[]` | Agent IDs allowed to run active recall |
| `openclaw_memory.active_memory.associative_recall.enabled` | bool | `false` | Enable native reinforced/unbidden recall injection for active-memory eligible turns |
| `openclaw_memory.active_memory.associative_recall.intrusion_rate` | number | `0.07` | Fraction of eligible turns that sample associative recall; Aineko-style deployments commonly use `0.15` on private agents only |
| `openclaw_memory.active_memory.associative_recall.max_snippets` | int | `1` | Maximum snippets injected on a triggered turn |
| `openclaw_memory.active_memory.associative_recall.min_signal_count` | int | `1` | Minimum recall/daily/grounded signal count before a snippet can resurface |
| `openclaw_memory.active_memory.associative_recall.max_age_days` | int | `90` | Exclude snippets last recalled more than this many days ago |
| `openclaw_memory.active_memory.associative_recall.include_structural` | bool | `true` | Blend graph/PyKEEN structural recall artifacts when `workspace/memory/graph/structural-recall.jsonl` exists |
| `openclaw_memory.dreaming.enabled` | bool | `false` | Enable `memory-core` dreaming sweeps |
| `openclaw_memory.dreaming.deep.promotion_target_path` | string | `memory/promoted.md` | Warm review file for automated deep promotions |
| `openclaw_memory.graph.enabled` | bool | `false` | Scaffold and optionally schedule graph-memory/PyKEEN artifacts for private memory agents |
| `openclaw_memory.graph.create_tools` | bool | `true` | Copy graph-memory pipeline/query/PyKEEN tools to `workspace/tools/graph-memory/` |
| `openclaw_memory.graph.include_sessions` | bool | `true` | Include session JSONL files in graph extraction when available |
| `openclaw_memory.graph.extractor` | string | `heuristic` | Graph extractor mode: deterministic `heuristic`, `agy`, or `auto` |
| `openclaw_memory.graph.agy_timeout` | int | `20` | Per-chunk `agy -p` timeout in seconds when agy extraction is enabled |
| `openclaw_memory.graph.agy_max_chunks` | int | `0` | Maximum chunks sent to agy; `0` means unlimited when agy extraction is enabled |
| `openclaw_memory.graph.run_on_deploy` | bool | `false` | Run graph extraction once during deploy |
| `openclaw_memory.graph.cron_enabled` | bool | `false` | Install a per-agent openclaw-user cron job for graph extraction |
| `openclaw_memory.graph.pykeen.enabled` | bool | `true` | Run `pykeen_structural.py`; it uses PyKEEN when installed and deterministic structural embeddings otherwise |
| `openclaw_memory.graph.pykeen.prediction_limit` | int | `200` | Maximum link-prediction rows exported under `workspace/memory/graph/pykeen/` |
| `openclaw_memory.scaffold.create_bootstrap_files` | bool | `true` | Create missing `AGENTS.md`, `SOUL.md`, `IDENTITY.md`, `USER.md`, `TOOLS.md`, and `HEARTBEAT.md` bootstrap files |
| `openclaw_memory.scaffold.create_tier2_files` | bool | `true` | Create missing warm tier-2 memory files under `memory/` |
| `openclaw_memory.scaffold.sidecar_queue_policy` | string | `fail` | `fail`, `warn`, or ignore legacy `.memory-queue` sidecars during state setup |
| `openclaw_memory.scaffold.create_recall_tool` | bool | `true` | Create missing `workspace/tools/aineko-recall.sh`, an `agy`-based brute-force recall helper |
| `openclaw_memory.scaffold.create_flush_tool` | bool | `true` | Create missing `workspace/tools/aineko-flush.sh`, an append-only canonical daily-log helper |

Use `memory/promoted.md` for automated promotions and keep
`workspace/MEMORY.md` human-curated. Associative recall reads memory-core's
short-term reinforcement state and `workspace/memory/graph/structural-recall.jsonl`
through native active-memory, then injects escaped untrusted metadata; enable it
only for private memory agents. The `agent_state` role scaffolds bootstrap
files, `MEMORY.md`, tier-2 warm files, `memory/promoted.md`, `memory/.dreams/`,
typed graph/PyKEEN artifacts under `workspace/memory/graph/`, the brute-force
recall helper, the append-only flush helper, and the daily log with
create-if-absent semantics only.

### openclaw_agents

Agent definitions. Empty by default; define in site config.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique agent identifier (used in directory paths) |
| `name` | string | no | Display name (defaults to `id`) |
| `skills` | list of string | no | Skills enabled for this agent (default: `[]`) |
| `memory.enabled` | bool | no | Per-agent native memory posture; overrides `openclaw_memory.enabled` |
| `memory_search` | bool | no | Enable memory search for the agent (default: `false`) |
| `state_repo` | string | no | Git repo URL for agent state (workspace + memory dumps) |
| `state_path` | string | no | Path within the state repo for this agent's data |

### telemetry

Observability stack (OTel Collector, Prometheus, Phoenix, Grafana, Caddy).

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telemetry.enabled` | bool | *(none)* | Enable the telemetry stack |
| `telemetry.host` | string | `127.0.0.1` | Host running the telemetry stack (set to remote IP for centralised collection) |

#### telemetry.otel_collector

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telemetry.otel_collector.grpc_port` | int | `4317` | OTLP gRPC port |
| `telemetry.otel_collector.http_port` | int | `4318` | OTLP HTTP port |
| `telemetry.otel_collector.version` | string | `0.120.0` | Collector image version |

#### telemetry.prometheus

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telemetry.prometheus.port` | int | `9090` | Prometheus listen port |
| `telemetry.prometheus.retention` | string | `30d` | Data retention period |
| `telemetry.prometheus.scrape_interval` | string | `15s` | Default scrape interval |
| `telemetry.prometheus.version` | string | `3.3.0` | Prometheus image version |

#### telemetry.phoenix

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telemetry.phoenix.port` | int | `6006` | Phoenix UI port |
| `telemetry.phoenix.prometheus_port` | int | `9091` | Phoenix `/metrics` endpoint port |
| `telemetry.phoenix.version` | string | `latest` | Phoenix version (`pip install arize-phoenix`) |
| `telemetry.phoenix.db_dir` | string | `/var/lib/phoenix` | Phoenix data directory |

#### telemetry.grafana

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telemetry.grafana.port` | int | `3000` | Grafana listen port |
| `telemetry.grafana.version` | string | `11.6.0` | Grafana image version |

#### telemetry.caddy

TLS-terminating reverse proxy in front of telemetry UIs.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telemetry.caddy.version` | string | `2.9.1` | Caddy image version |
| `telemetry.caddy.grafana_port` | int | `3443` | HTTPS port for Grafana |
| `telemetry.caddy.prometheus_port` | int | `9443` | HTTPS port for Prometheus |
| `telemetry.caddy.phoenix_port` | int | `6443` | HTTPS port for Phoenix |

---

## Host Variables (`inventory/host_vars/<hostname>.yml`)

Per-host overrides, defined per inventory host.

| Variable | Type | Description |
|----------|------|-------------|
| `host_ip` | string | Host's LAN IP address |
| `openclaw_channels` | dict | Legacy channel configs (non-agent-scoped). Empty when all channels are agent-scoped. |
| `openclaw_gateway_token` | string | Gateway bearer token (vault reference) |
| `openclaw_gateway_password` | string | Gateway password (vault reference) |

### Agent Slack identity (`openclaw_agents[].slack`)

When an agent defines a `slack` block, OpenClaw runs that agent's Slack identity
as a separate account. The gateway uses `bindings` to route messages from each
Slack account to its owning agent. Agents without a `slack` block have no Slack
presence and are only reachable via the gateway UI.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `slack.bot_token` | string | `""` | Raw Slack bot token. Required only when `locksmith.slack_native.enabled=false`; ignored by the default fake-token transport path. |
| `slack.app_token` | string | `""` | Raw Slack app-level Socket Mode token. Required only when `locksmith.slack_native.enabled=false` and `slack.mode=socket`. |
| `slack.user_token` | string | `""` | Optional raw Slack user token. With native transport enabled, its presence requests a fake xoxp handle instead of rendering the raw token. |
| `slack.bot_handle` | string | `xoxb-locksmith-<agent>` | Optional fake bot-token handle rendered into OpenClaw when native Slack transport is enabled |
| `slack.app_handle` | string | `xapp-locksmith-<agent>` | Optional fake app-token handle rendered into OpenClaw when native Slack transport is enabled |
| `slack.user_handle` | string | `xoxp-locksmith-<agent>` | Optional fake user-token handle rendered into OpenClaw when native Slack transport is enabled |
| `slack.credential_proxy.enabled` | bool | `locksmith.slack_native.enabled` | Disable to render raw `slack.bot_token`/`slack.app_token` into OpenClaw intentionally |
| `slack.mode` | string | `socket` | Connection mode: `socket` or `http` |
| `slack.dm_policy` | string | inherited OpenClaw default (`pairing`) | DM access policy rendered as `dmPolicy`; `open` requires `slack.allow_from: ["*"]` |
| `slack.allow_from` | list | inherited OpenClaw default | DM/operator allowlist rendered as `allowFrom` |
| `slack.default_to` | string | *(none)* | Default outbound Slack target such as `user:U...` |
| `slack.group_policy` | string | `allowlist` | Channel access policy (`allowlist` or `open`) |
| `slack.channels` | object | *(none)* | Account-scoped Slack channel policy rendered verbatim as `channels.slack.accounts.<agent>.channels` |
| `slack.dms` | object | *(none)* | Account-scoped Slack DM policy rendered verbatim as `dms` |
| `slack.dm` | object | *(none)* | Account-scoped Slack DM policy rendered verbatim as `dm` |
| `slack.allow_bots` | bool/string | *(none)* | Account-level `allowBots` override |
| `slack.require_mention` | bool | *(none)* | Account-level `requireMention` override |
| `slack.account_config` | object | *(none)* | Advanced OpenClaw-native Slack account fields merged into the rendered account; generated fake token handles still win |
| `slack.streaming` | object/string | `{mode: partial}` | Stream preview mode. Object form is canonical; legacy scalar values are normalized by the template. |

### Agent Telegram identity (`openclaw_agents[].telegram`)

Same pattern as Slack — each agent can have its own Telegram bot.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telegram.bot_token` | string | *(required)* | Telegram bot token |
| `telegram.dm_policy` | string | `pairing` | DM access policy |
| `telegram.group_policy` | string | `allowlist` | Group access policy |
| `telegram.group_allow_from` | list of string | *(none)* | Telegram user/bot IDs allowed in groups (when `group_policy: allowlist`). Use bot IDs for inter-agent group chats. |
| `telegram.streaming` | string | `partial` | Stream preview mode |

### Legacy channel fields (per entry in `openclaw_channels`)

Used only when no agent defines the corresponding channel block.

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable this channel |
| `botToken` | string | Bot token (vault reference) |
| `dmPolicy` | string | DM policy (e.g. `pairing`) |
| `groupPolicy` | string | Group policy (e.g. `allowlist`) |
| `streaming` | string | Streaming mode (e.g. `partial`) |

---

## Version Upgrades

Set `openclaw_version` in site config and deploy with `--tags service`:

```bash
ansible-playbook -i ../site/inventory/hosts.yml playbook.yml \
  --tags service --limit <host> --ask-vault-pass
```

The upgrade task (`openclaw_service` role) will:

1. Stop OpenClaw
2. Stop Pipelock
3. Insert a temporary nftables rule allowing the `openclaw` user direct
   internet egress on ports 80/443
4. Run `pnpm add -g openclaw@<version>`
5. Remove the temporary nftables rule
6. Start Pipelock and verify it is active
7. Start OpenClaw
8. Run the `verify` role (posture check)

**Why the nftables workaround?** pnpm's HTTPS client is incompatible with
Pipelock's CONNECT tunnel proxy. Parallel dependency resolution exhausts the
proxy rate limit and triggers 403 errors. The temporary direct-egress rule
bypasses the proxy for the install only; Pipelock and nftables are fully
restored immediately after.

To skip version management, set `openclaw_version: "latest"` (the default).

---

## Vault Variables

All secrets are stored in `group_vars/agent_hosts/vault.yml` (encrypted with
`ansible-vault`).  Generated by `bootstrap-vault.yml`.

| Variable | Used by |
|----------|---------|
| `vault_<agentid>_telegram_bot_token` | `openclaw_agents[].telegram.bot_token` |
| `vault_telegram_bot_token` | *(deprecated)* Legacy `openclaw_channels.telegram.botToken` |
| `vault_slack_bot_token` / `SLACK_BOT_TOKEN` | Real Slack xoxb token for `locksmith.slack_native` |
| `vault_slack_app_token` / `SLACK_APP_TOKEN` | Real Slack xapp Socket Mode token for `locksmith.slack_native` |
| `vault_slack_user_token` / `SLACK_USER_TOKEN` | Optional real Slack xoxp token for `locksmith.slack_native.include_user` |
| `vault_anthropic_api_key` | `inference.endpoints[].api_key` (Anthropic) |
| `vault_openai_api_key` | `inference.endpoints[].api_key` (OpenAI) |
| `vault_tokenator_pat` | `inference.endpoints[].api_key` (Kamiwaza tokenator) |
| `vault_github_token` | `locksmith.tools[].api_key` (GitHub) |
| `vault_tavily_api_key` | `locksmith.tools[].api_key` (Tavily) |
| `vault_firecrawl_api_key` | `locksmith.tools[].api_key` (Firecrawl) |
| `vault_locksmith_inbound_token` | `locksmith.inbound_token` |
| `vault_openclaw_gateway_token` | `openclaw_gateway_token` (host_vars) |
| `vault_openclaw_gateway_password` | `openclaw_gateway_password` (host_vars) |
