# Locksmith v2 in OpenClaw Hardened

## Goal

OpenClaw Hardened should deploy Pipelock, Locksmith, and OpenClaw as one default boundary. Pipelock owns outbound network policy. Locksmith owns tool credential injection and tool discovery. OpenClaw receives only the authority needed to call Locksmith and should not receive raw upstream tool credentials.

The hardened default is not an optional add-on path. A normal install should bring up Pipelock, Locksmith, the OpenClaw Locksmith plugin, and the OpenClaw service dependency chain together. Operators can still use explicit override switches for local repair, but the shipped posture is that OpenClaw calls tools through Locksmith and Locksmith routes internet-bound upstreams through Pipelock.

## Current Gap

The old deployment assumed a single `locksmith` binary that was both daemon and CLI. Locksmith v2 split that surface into `locksmithd` for the long-running daemon and `locksmith` for operator and agent CLI commands. OpenClaw Hardened must therefore install and validate both binaries, but the system service and host LaunchDaemon must execute `locksmithd --config ...`.

The old deployment also rendered M0-era tool config fields such as `cloud: true` and `timeout_seconds`. Locksmith v2 still translates those as deprecated compatibility fields, but the hardened deployment should render the current shape directly: per-tool `egress: direct|proxied`, `timeouts.request_seconds`, `timeouts.idle_seconds`, optional `body_limit_bytes`, and optional `response` controls.

## Default Runtime Contract

On Linux agent hosts, the role installs `locksmithd` and `locksmith`, renders `/etc/locksmith/config.yaml`, writes secret environment material to `/etc/locksmith/locksmith.env`, starts `locksmith.service`, and verifies the public liveness/readiness/catalog surface. The daemon binds to loopback by default on port 9200. Internet-bound tool registrations use `egress: proxied` and therefore use Pipelock as the HTTP CONNECT proxy.

On macOS host-boundary deployments, Pipelock and Locksmith are both host services. Locksmith binds loopback-only on the private host port, and the existing PF-gated bridge exposes the VM-facing port to trusted Lima guests. The LaunchDaemon wrapper carries secrets and executes `locksmithd`, not the CLI.

OpenClaw receives `LOCKSMITH_INBOUND_TOKEN` in its service environment when configured. The OpenClaw plugin is rendered in required mode and points at the local Locksmith listener. Static tools and selected Kamiwaza-discovered MCP slugs can be projected as first-class OpenClaw tools, but the actual upstream credential injection stays inside Locksmith.

## Authentication Shape

The default hardened deployment keeps Locksmith's M0-compatible shared inbound bearer because OpenClaw currently has one plugin token setting. This means `inbound_auth.token` is rendered only when `locksmith.inbound_token` is supplied, and OpenClaw gets the same token through `env:LOCKSMITH_INBOUND_TOKEN`.

Locksmith v2 also supports richer admin substrate and per-agent bearers, but enabling `listen.admin_socket` changes bearer semantics and requires agent registration before the agent listener accepts calls. That is a good future hardening step, but it is not the default here because it would make a clean OpenClaw install depend on a second bootstrap workflow that OpenClaw does not yet drive.

## Install Shape

The deployment supports release downloads and source builds. The release contract is two artifacts per platform: `locksmithd-<platform>` for the daemon and `locksmith-<platform>` for the CLI. Until every release has both artifacts, `install_method: auto` can fall back to the sibling `../exocortex-agent-locksmith` source checkout and build Linux binaries on the target with Docker.

The systemd service must validate that `locksmithd --help` identifies the daemon after install. This catches the common failure where an old release asset named `locksmith-linux-amd64` is actually the CLI and cannot serve `--config`.

## Configuration Shape

Each static tool renders as:

```yaml
tools:
  - name: example
    description: Example API
    upstream: https://api.example.com
    egress: proxied
    auth:
      header: Authorization
      value:
        from_env:
          var: EXAMPLE_TOKEN
          prefix: Bearer
    timeouts:
      request_seconds: 30
      idle_seconds: 60
    body_limit_bytes: 10485760
```

Tools that do not require auth omit the `auth` block. `cloud: true` in site config remains accepted as an operator convenience, but the rendered daemon config should translate it into `egress: proxied`.

Kamiwaza support is a Locksmith provider block plus optional OpenClaw projection. The provider owns live discovery and token injection. OpenClaw projection only decides which discovered slugs appear as explicit OpenClaw tools.

## Preservation During Reinstall

Before a reinstall or role rerun against existing Lima guests, preserve the live OpenClaw and boundary configs. The important material is `/home/openclaw/.openclaw`, `/etc/openclaw`, `/etc/locksmith`, `/etc/pipelock`, and relevant systemd unit files inside the Linux guest, plus host-boundary configs under `/usr/local/etc/openclaw-boundary`, `/Library/LaunchDaemons/com.exocortex.openclaw.*.plist`, and `/etc/pf.anchors/openclaw-host-boundary` on the macOS host.

The Ansible roles already back up `openclaw.json` before rewriting it. The Locksmith role should also archive the existing config and environment file before changing them, because those files may carry local tokens that are tedious to recreate.

## Acceptance Criteria

1. A default Linux playbook run executes the Locksmith role because the hardened default enables it.
2. The target has executable `locksmithd` and `locksmith` binaries, and `locksmith.service` starts `locksmithd --config /etc/locksmith/config.yaml`.
3. Rendered Locksmith config uses v2 fields for egress, timeouts, body limits, and response controls.
4. OpenClaw service ordering includes Pipelock and Locksmith, and OpenClaw gets only the Locksmith inbound token, not upstream API keys.
5. OpenClaw config renders the Locksmith plugin in required mode by default and can project static tools plus selected Kamiwaza MCP slugs.
6. Host-boundary LaunchDaemons follow the same daemon/CLI split and v2 config shape.
7. Verification checks `locksmithd`, `locksmith`, `/livez`, `/readyz`, `/version`, and `/tools`, including auth rejection when an inbound token is configured.
8. A full reinstall or rerun preserves the live config archive before overwriting OpenClaw, Locksmith, or host-boundary config.
