# openclaw-hardened

Security-hardened deployment framework for [OpenClaw](https://github.com/openclaw) with defense-in-depth.

## What's Included

- **Ansible roles** for Docker hardening (gVisor), egress control (Pipelock), firewall (nftables), LLM proxy (LlamaFirewall), credential proxy (Locksmith), telemetry stack (OTel/Prometheus/Phoenix/Grafana/Caddy)
- **Agent state management** — clone repos, link workspaces, restore memory
- **Verification** — automated security posture checks

## Quick Start

1. Clone this repo and create a site config repo:
   ```bash
   git clone https://github.com/SentientSwarm/openclaw-hardened.git
   mkdir my-site && cd my-site
   cp -r ../openclaw-hardened/examples/* .
   ```

2. Edit the example files with your deployment values (see [Site Config Schema](docs/site-config-schema.md))

3. Bootstrap vault secrets:
   ```bash
   ansible-playbook bootstrap-vault.yml --ask-vault-pass
   ```

4. Deploy:
   ```bash
   ./run.sh --ask-vault-pass --ask-become-pass
   ```

## Documentation

- [Site Config Schema](docs/site-config-schema.md) — all variables documented
- [Design](docs/2026-03-08-platform-site-split-design.md) — architecture overview

## License

MIT
