# Site Configuration Schema

All variables for an openclaw-hardened-site deployment, defined in
`group_vars/agent_hosts/main.yml` unless otherwise noted.  Role defaults
live in `roles/<role>/defaults/main.yml` and are overridden by site config.

> **Important:** Ansible uses shallow dict merge. If you override **any** key
> in a dict (e.g. `pipelock`), you must include the **entire** dict in your
> site config. Role defaults only apply when the top-level dict is completely
> absent from site config.

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
| `locksmith.enabled` | bool | `false` | Enable Locksmith |
| `locksmith.version` | string | `latest` | Container image tag |
| `locksmith.listen_host` | string | `127.0.0.1` | Bind address |
| `locksmith.listen_port` | int | `9200` | Listen port |
| `locksmith.log_level` | string | `info` | Log level |
| `locksmith.inbound_token` | string | `""` | Bearer token agents must present (vault reference) |
| `locksmith.tools` | list of tool objects | `[]` | Tool definitions (see below) |

#### Locksmith tool fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Tool slug (URL path component) |
| `description` | string | yes | Human-readable description |
| `upstream` | string | yes | Upstream base URL |
| `cloud` | bool | yes | Route via Pipelock CONNECT tunnel |
| `api_key` | string | yes | Credential to inject (vault reference) |
| `api_key_header` | string | yes | Header name for the credential |
| `api_key_prefix` | string | yes | Prefix before key value (empty string for none) |
| `api_key_env` | string | no | Environment variable name exposed to containers |
| `timeout_seconds` | int | no | Request timeout |

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
| `openclaw.ansible_repo` | string | *(none)* | URL of openclaw-ansible repo (Phase 1 installer) |
| `openclaw.ansible_branch` | string | `main` | Branch to checkout |
| `openclaw.gateway_bind` | string | `lan` | Gateway bind mode (`lan` or `0.0.0.0`) |
| `openclaw.gateway_port` | int | `18789` | Gateway listen port |
| `openclaw.gateway_auth_mode` | string | `password` | Auth mode: `password` or `token` |
| `openclaw.sandbox.mode` | string | `non-main` | Sandbox mode for agent containers |
| `openclaw.sandbox.docker_network` | string | `bridge` | Docker network for sandboxed containers |
| `openclaw.sandbox.read_only_root` | bool | `true` | Mount container root filesystem read-only |
| `openclaw.sandbox.memory` | string | `2g` | Container memory limit |
| `openclaw.sandbox.cpus` | int | `2` | Container CPU limit |
| `openclaw.sandbox.pids_limit` | int | `256` | Container PID limit |
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

### openclaw_agents

Agent definitions. Empty by default; define in site config.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique agent identifier (used in directory paths) |
| `name` | string | no | Display name (defaults to `id`) |
| `skills` | list of string | no | Skills enabled for this agent (default: `[]`) |
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
| `openclaw_channels` | dict | Channel configurations keyed by provider name (see below) |
| `openclaw_gateway_token` | string | Gateway bearer token (vault reference) |
| `openclaw_gateway_password` | string | Gateway password (vault reference) |

### Channel fields (per entry in `openclaw_channels`)

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable this channel |
| `botToken` | string | Bot token (vault reference) |
| `dmPolicy` | string | DM policy (e.g. `pairing`) |
| `groupPolicy` | string | Group policy (e.g. `allowlist`) |
| `streaming` | string | Streaming mode (e.g. `partial`) |

---

## Vault Variables

All secrets are stored in `group_vars/agent_hosts/vault.yml` (encrypted with
`ansible-vault`).  Generated by `bootstrap-vault.yml`.

| Variable | Used by |
|----------|---------|
| `vault_telegram_bot_token` | `openclaw_channels.telegram.botToken` |
| `vault_slack_bot_token` | `openclaw_channels.slack.botToken` |
| `vault_anthropic_api_key` | `inference.endpoints[].api_key` (Anthropic) |
| `vault_openai_api_key` | `inference.endpoints[].api_key` (OpenAI) |
| `vault_tokenator_pat` | `inference.endpoints[].api_key` (Kamiwaza tokenator) |
| `vault_github_token` | `locksmith.tools[].api_key` (GitHub) |
| `vault_tavily_api_key` | `locksmith.tools[].api_key` (Tavily) |
| `vault_firecrawl_api_key` | `locksmith.tools[].api_key` (Firecrawl) |
| `vault_locksmith_inbound_token` | `locksmith.inbound_token` |
| `vault_openclaw_gateway_token` | `openclaw_gateway_token` (host_vars) |
| `vault_openclaw_gateway_password` | `openclaw_gateway_password` (host_vars) |
