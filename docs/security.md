# Security Model

This document describes the security architecture of openclaw-hardened, an
Ansible-based deployment framework that wraps [OpenClaw](https://github.com/openclaw/openclaw)
with network-level egress controls, inference-layer scanning, credential
isolation, and configuration lockdown. It is written for security-conscious
developers evaluating whether this deployment is safe for production AI agents.

---

## Threat Model

### What we protect against

| Threat | Primary defense | Secondary defense |
|--------|----------------|-------------------|
| Agent exfiltrating data via unauthorized egress | nftables drops all non-Pipelock internet traffic | Pipelock domain allowlist, DLP scanning, rate limiting |
| Agent accessing external services not on the allowlist | Pipelock enforces a domain allowlist with glob matching | Explicit blocklist for known exfiltration services (pastebin, ngrok, transfer.sh, requestbin, webhook.site) |
| Prompt injection attacks via inference requests | LlamaFirewall with PromptGuard 2 (86M-parameter classifier) | CodeShield (Semgrep-based) scans generated code |
| Agent modifying its own configuration, proxy settings, or tool restrictions | `openclaw.json` owned by `root:openclaw 0640` -- agents can read but not write | nftables enforcement is independent of proxy env vars |
| Cross-agent data access (when sandbox is enabled) | Docker-based sandbox with per-agent workspace mounts | gVisor (`runsc`) as the default container runtime |
| API credential exposure to the agent or in logs | Locksmith injects credentials at the proxy layer -- agents never see API keys | `no_log: true` and `loop_control: label` on Ansible tasks handling secrets |
| Reconnaissance and automated attack patterns | Pipelock tool-chain detection (sliding window, configurable action) | Rate limiting (60 req/min default), max URL length (2048), entropy analysis |
| Excessive inference spend | LlamaFirewall per-provider monthly budget enforcement | Budget state persisted to disk, checked on every request |
| Unauthorized gateway access | Gateway authentication (password or token mode) | nftables restricts gateway port to management CIDRs only |
| Unauthorized messaging channel access | Telegram `pairing` policy, Slack `allowlist` group policy | Per-agent channel bindings -- each agent has its own bot identity |

### What we do NOT protect against

These are real limitations. We list them here because honest assessment builds
more trust than a false sense of completeness.

- **Compromise of the Ansible control machine.** The control machine holds
  vault passwords and SSH keys. If it is compromised, an attacker can
  re-deploy with arbitrary configuration. Protect it with full-disk
  encryption, MFA, and restricted access.

- **Physical or root access to the target host.** An attacker with root can
  modify nftables rules, read vault-decrypted secrets in memory, or replace
  binaries. Standard host hardening (BIOS passwords, secure boot, disk
  encryption) is outside our scope.

- **Vulnerabilities in OpenClaw itself.** We wrap OpenClaw with security
  controls; we do not audit its source code. A vulnerability in OpenClaw's
  gateway, session handling, or plugin system could bypass our controls.
  Track upstream security advisories independently.

- **Malicious operators with vault access.** Anyone who can decrypt the
  Ansible vault can read every secret in the deployment. Use strong vault
  passwords and limit who knows them.

- **Side-channel attacks between agents sharing the same host.** When the
  sandbox is off, agents run as the same Unix user and can read each other's
  workspaces and memory. Even with the sandbox on, agents share the same
  kernel (gVisor notwithstanding) and may be vulnerable to timing or
  resource-based side channels.

- **DNS-based exfiltration.** nftables allows DNS to the gateway IP. An
  agent could encode data in DNS queries. Mitigate with a DNS firewall or
  logging DNS resolver on the gateway, but this is not currently deployed.

- **Supply-chain attacks on deployed binaries.** Pipelock, Locksmith, and
  LlamaFirewall are downloaded from GitHub releases. We do not currently
  verify signatures or checksums beyond HTTPS transport security.

---

## Defense-in-Depth Summary

| Layer | Component | Threat mitigated | Enforcement |
|-------|-----------|-----------------|-------------|
| Network (L3/L4) | **nftables** | Direct internet egress by any user except `pipelock` | Kernel-level packet filtering; `skuid pipelock` rule permits only the Pipelock process to reach external hosts on ports 80/443. All other egress to non-RFC1918 addresses is dropped and logged with `nft-egress-block:` prefix. |
| Network (L3/L4) | **nftables input chain** | Unauthorized inbound access | Default-drop input policy. Only management CIDRs reach SSH, gateway, and telemetry ports. Docker bridge and allowed LAN IPs are explicitly permitted. |
| Network (L7) | **Pipelock** | Unauthorized destination access, data exfiltration | HTTPS forward proxy with domain allowlist. SNI verification enabled. Blocks known exfiltration domains. DLP engine scans for secret patterns and high-entropy strings in outbound traffic. |
| Network (L7) | **Pipelock tool-chain detection** | Multi-step exfiltration (fetch-then-post patterns) | Sliding window analysis (default: 20 requests over 300 seconds) detects sequential tool-chain patterns. Configurable to `warn` or `block`. |
| Network (L7) | **Pipelock rate limiting** | Automated abuse, brute-force scanning | 60 requests per minute per source (configurable). URL length capped at 2048 characters. |
| Inference | **LlamaFirewall (PromptGuard 2)** | Prompt injection in user inputs and tool outputs | On-device 86M-parameter classifier scans every inference request before forwarding to the upstream model. |
| Inference | **LlamaFirewall (CodeShield)** | Unsafe generated code | Semgrep-based static analysis scans model-generated code for security issues. |
| Inference | **LlamaFirewall (budget)** | Runaway inference spend | Per-provider monthly spend caps. State file persisted to `/var/lib/llamafirewall/budget.json`. |
| Credential | **Locksmith** | API key exposure to agents | Reverse proxy injects credentials into upstream requests. Agents authenticate to Locksmith with an inbound bearer token; they never see the upstream API keys. |
| Credential | **Ansible Vault** | Secret storage at rest | AES-256 encrypted vault file. Per-agent secrets use `vault_<agentid>_*` naming. |
| Credential | **Ansible task hygiene** | Secret leakage in deployment logs | `no_log: true` on credential-handling tasks. `loop_control: label` prevents token values from appearing when iterating over agent lists. |
| Configuration | **File ownership lockdown** | Agent self-modification | `openclaw.json` deployed as `root:openclaw 0640`. Agents can read the config (required for operation) but cannot write to it. |
| Configuration | **nftables independence** | Proxy bypass via env var manipulation | Even if an agent could modify `HTTP_PROXY` or `HTTPS_PROXY`, nftables still drops direct egress. Removing the proxy env vars causes requests to time out, not bypass the proxy. |
| Isolation | **Docker sandbox** (when enabled) | Filesystem and resource abuse | Per-session containers with read-only root, memory limits, CPU limits, PID limits. gVisor (`runsc`) as the default OCI runtime adds a user-space kernel boundary. |
| Isolation | **Unix user separation** | Privilege escalation | `openclaw`, `pipelock`, `locksmith`, and `llamafirewall` each run as dedicated system users with `nologin` shells and no home directories (except `openclaw`). |
| Access control | **Gateway authentication** | Unauthorized agent interaction | Password or token authentication on the gateway. TLS enabled with HSTS headers. |
| Access control | **Channel policies** | Unauthorized messaging access | Telegram uses `pairing` (users must be approved). Slack uses `allowlist` group policy. Each agent has its own bot identity with scoped channel bindings. |
| Audit | **Deployment verification** | Configuration drift | `verify-posture.sh` runs automated checks after every deployment: service status, nftables rules, egress blocking, proxy function, sandbox state. Fails the playbook on non-compliance. |

---

## Sandbox Status

### Current state: disabled

The sandbox is set to `off` in the default configuration. This is a deliberate
trade-off, not an oversight.

**Why the sandbox is off:** OpenClaw's sandbox applies path restrictions that
block reads to the platform's own install directory
(`~/.local/share/pnpm/...`). Built-in skills and documentation live under this
path. When the sandbox is active, agents fail on basic skill-loading and
research operations because there is no `allowedReadPaths` configuration
option to extend the sandbox root.

**Impact:** Agents run tool calls directly as the `openclaw` user on the host.
There is no filesystem isolation, no per-session resource limits, and no
network namespace separation between tool calls.

### Mitigations while sandbox is off

These controls remain fully active regardless of sandbox state:

| Control | What it does | Why it matters without the sandbox |
|---------|-------------|-----------------------------------|
| `openclaw.json` owned `root:openclaw 0640` | Agents cannot modify their own config | Prevents agents from changing proxy settings, tool profiles, model endpoints, or disabling security features |
| nftables egress blocking | All direct internet traffic from the `openclaw` user is dropped | Even if an agent unsets `HTTP_PROXY`, requests time out instead of bypassing the proxy |
| Pipelock domain allowlist | Only approved domains are reachable | Limits the blast radius of any tool call that makes HTTP requests |
| LlamaFirewall inference scanning | All inference traffic is scanned for prompt injection | Operates at the proxy layer, independent of where tool calls execute |
| OpenClaw tools profile | Restricts which tools are available to agents | Limits capabilities regardless of filesystem access |
| Unix permissions | `openclaw` user has no sudo, no elevated privileges | Standard Unix DAC applies to all file and process operations |

### What you lose without the sandbox

Be explicit about this with your security reviewers:

- **Filesystem isolation** -- agents can read and write anything the `openclaw`
  user can access, including other agents' workspaces and memory directories.
- **Resource limits** -- no memory, CPU, or PID caps on tool execution. A
  runaway process can exhaust host resources.
- **Network namespace isolation** -- tool calls use the host network stack
  (still constrained by nftables and Pipelock, but not isolated from each
  other).
- **Cross-agent data access** -- one agent can read another agent's session
  transcripts, workspace files, and memory store.

### Re-enabling the sandbox

When OpenClaw adds `allowedReadPaths` or an equivalent mechanism to extend the
sandbox root, set `openclaw.sandbox.mode` back to `"non-main"` in site config.
The sandbox configuration block in `openclaw.json` already includes resource
limits (`memory`, `cpus`, `pidsLimit`) and `readOnlyRoot: true` -- these will
take effect automatically when the mode is changed.

---

## Configuration Lockdown

The `openclaw_config` role deploys `openclaw.json` with specific ownership and
permissions:

```
owner: root
group: openclaw
mode:  0640
```

This means:

- **root** can read and write the file (Ansible deploys as root).
- **openclaw** (group) can read the file (needed for the OpenClaw process to
  start and operate).
- **All other users** have no access.
- **The openclaw user cannot write to the file.** This is the critical
  property.

What this prevents an agent from doing, even without the sandbox:

- Changing `HTTP_PROXY` / `HTTPS_PROXY` to point to a different proxy or
  removing them entirely
- Modifying the `tools.profile` to gain access to restricted tools
- Altering model provider `baseUrl` entries to bypass LlamaFirewall
- Changing gateway authentication settings
- Disabling security features in the config

What this does NOT prevent:

- An agent reading the config file (it can see model endpoint URLs, proxy
  addresses, and the tools profile -- but not vault-encrypted secrets, which
  are decrypted only during Ansible deployment)
- An agent modifying environment variables in its own process (but nftables
  makes this ineffective for proxy bypass)

---

## Credential Security

### Storage

All secrets are stored in `group_vars/agent_hosts/vault.yml`, encrypted with
`ansible-vault` (AES-256). The vault file is decrypted only during Ansible
runs and secrets are injected into templates at deployment time.

### Naming convention

Per-agent secrets follow a consistent pattern:
- `vault_<agentid>_slack_bot_token`
- `vault_<agentid>_slack_app_token`
- `vault_<agentid>_telegram_bot_token`

Shared secrets use descriptive names:
- `vault_anthropic_api_key`
- `vault_openai_api_key`
- `vault_locksmith_inbound_token`
- `vault_openclaw_gateway_token`

### Credential injection

Locksmith acts as a credential-injecting reverse proxy. The flow:

1. Agent makes a request to `http://localhost:9200/tools/<tool-name>/...`
2. Agent authenticates with a bearer token (the `inbound_token`)
3. Locksmith looks up the tool's upstream URL and API key
4. Locksmith forwards the request with the real API key injected in the
   configured header
5. The agent never sees the upstream API key

Locksmith's config is owned by `root:locksmith 0640` -- the agent cannot
read it.

### Log safety

Ansible tasks that handle credentials use two mechanisms to prevent leakage:

- `no_log: true` on tasks that process secret values
- `loop_control: label: "{{ item.id }}"` on tasks that iterate over
  `openclaw_agents`, so that loop output shows agent IDs instead of the full
  agent dict (which may contain token references)

### What remains visible to agents

- The Locksmith inbound token (in the OpenClaw config or environment) --
  this authenticates the agent to Locksmith but does not grant access to
  upstream API keys
- Inference endpoint base URLs (in `openclaw.json`) -- these point to
  LlamaFirewall, not directly to upstream providers when LlamaFirewall is
  enabled
- The `api_key` field in the models config -- when LlamaFirewall is enabled,
  this is typically `"not-required"` since LlamaFirewall handles upstream auth

---

## Audit Trail

### Pipelock (egress proxy)

All proxied requests are logged with:
- Destination domain and port
- HTTP method
- Response status code
- DLP scan results (secret pattern matches, entropy alerts)
- Tool-chain detection events
- Rate limit violations

Logs are written to `/var/log/pipelock/`.

### LlamaFirewall (inference proxy)

All inference requests are logged with:
- Provider name and model
- Request timing
- Token usage (input and output)
- PromptGuard scan results (injection probability scores)
- CodeShield findings
- Budget state (spend vs. cap)

Logs are written to `/var/log/llamafirewall/`.

### nftables (kernel firewall)

Blocked egress is logged to the kernel log with prefixes:
- `nft-egress-block:` -- non-Pipelock user attempted internet egress
- `nft-output-drop:` -- output dropped by default policy
- `nft-input-drop:` -- inbound connection dropped

Rate-limited to 5 log entries per minute per rule to prevent log flooding.

### OpenClaw (agent runtime)

- Session transcripts stored per-agent under
  `~/.openclaw/agents/<agent-id>/`
- Gateway access logs

### Telemetry stack (optional)

When `telemetry.enabled` is set:
- **OpenTelemetry Collector** receives traces and metrics from OpenClaw and
  LlamaFirewall
- **Prometheus** stores metrics with configurable retention (default: 30 days)
- **Loki + Promtail** (when configured) centralizes logs from all components
- **Phoenix** provides LLM-specific observability (trace visualization, token
  usage analysis)
- **Grafana** dashboards for unified monitoring
- **Caddy** TLS-terminates all telemetry UIs, restricted to management CIDRs
  by nftables

---

## Hardening Checklist

Run this checklist after every deployment. The automated `verify-posture.sh`
script covers most of these, but manual review is still valuable.

### Services

- [ ] `openclaw` service is active: `systemctl is-active openclaw`
- [ ] `pipelock` service is active: `systemctl is-active pipelock`
- [ ] `nftables` service is enabled: `systemctl is-enabled nftables`
- [ ] `fail2ban` service is active: `systemctl is-active fail2ban`
- [ ] `locksmith` service is active (if enabled): `systemctl is-active locksmith`
- [ ] `llamafirewall` service is active (if enabled): `systemctl is-active llamafirewall`
- [ ] Telemetry services are active (if enabled): otel-collector, prometheus, phoenix, grafana, caddy

### Vault and credentials

- [ ] Vault file is encrypted: `head -1 group_vars/agent_hosts/vault.yml` should show `$ANSIBLE_VAULT;1.1;AES256`
- [ ] No plaintext secrets in `group_vars/` or `host_vars/`: grep for `xoxb-`, `sk-`, `Bearer`, API key patterns
- [ ] Locksmith rejects unauthenticated requests: `curl -s -o /dev/null -w '%{http_code}' http://localhost:9200/tools` should return `401`

### Configuration lockdown

- [ ] `openclaw.json` ownership is `root:openclaw`: `stat -c '%U:%G' /home/openclaw/.openclaw/openclaw.json`
- [ ] `openclaw.json` permissions are `0640`: `stat -c '%a' /home/openclaw/.openclaw/openclaw.json`
- [ ] Locksmith config ownership is `root:locksmith 0640`: `stat -c '%U:%G %a' /etc/locksmith/config.yaml`

### Network

- [ ] nftables table is loaded: `nft list tables | grep 'inet openclaw'`
- [ ] nftables output chain has skuid rule: `nft list chain inet openclaw output | grep skuid`
- [ ] Direct egress is blocked for `openclaw` user: `sudo -u openclaw curl -sf --max-time 3 https://httpbin.org/ip` should fail
- [ ] Direct egress is blocked for `root`: `curl -sf --max-time 3 https://httpbin.org/ip` should fail
- [ ] Egress works through Pipelock: `curl -sf --proxy http://0.0.0.0:8888 --max-time 5 https://api.anthropic.com/` should succeed
- [ ] UFW is disabled (conflicts with nftables): `systemctl is-active ufw` should return `inactive`

### Pipelock

- [ ] Pipelock is listening: `ss -tlnp | grep :8888`
- [ ] Pipelock config exists: `test -f /etc/pipelock/pipelock.yaml`
- [ ] Enforce mode is on: check `enforce: true` in `/etc/pipelock/pipelock.yaml`
- [ ] Blocklist includes exfiltration domains: check for `pastebin`, `ngrok`, `transfer.sh` in config
- [ ] DLP secret pattern detection is enabled: check `secret_patterns: true`

### LlamaFirewall (if enabled)

- [ ] LlamaFirewall is listening: `ss -tlnp | grep :9100`
- [ ] Health endpoint responds: `curl -sf http://localhost:9100/health`
- [ ] PromptGuard model is loaded (check startup logs): `journalctl -u llamafirewall | grep -i promptguard`
- [ ] Inference endpoints are routed through LlamaFirewall: check `baseUrl` in `openclaw.json` points to `localhost:9100`, not directly to upstream

### Gateway authentication

- [ ] Gateway auth mode is `password` or `token` (not disabled): check `gateway.auth.mode` in `openclaw.json`
- [ ] Gateway TLS is enabled: check `gateway.tls.enabled: true` in `openclaw.json`
- [ ] HSTS header is set: check `strictTransportSecurity` in `openclaw.json`
- [ ] Gateway port is restricted to management CIDRs in nftables

### Messaging channels

- [ ] Telegram DM policy is `pairing` (not `open`): check `dmPolicy` in `openclaw.json`
- [ ] Slack group policy is `allowlist`: check `groupPolicy` in `openclaw.json`
- [ ] Each agent has its own bot identity (no shared tokens across agents)

### Ansible output safety

- [ ] Run a deployment with `--diff` and verify no secrets appear in output
- [ ] Confirm `no_log: true` is set on credential-handling tasks
- [ ] Confirm `loop_control: label` is used when iterating over agent lists with embedded secrets

### Docker and container hardening

- [ ] Default runtime is gVisor: `docker info | grep 'Default Runtime'` should show `runsc`
- [ ] `no-new-privileges` is set in `/etc/docker/daemon.json`
- [ ] gVisor is functional: `docker run --rm ubuntu:24.04 dmesg 2>&1 | grep 'Starting gVisor'`
- [ ] Docker pulls work through Pipelock: `docker pull --quiet debian:bookworm-slim`

### Automated verification

- [ ] Run `verify-posture.sh` and confirm `COMPLIANT` with zero failures
- [ ] Review any `SKIP` entries -- they may indicate services that need attention
