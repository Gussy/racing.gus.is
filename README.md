# racing.gus.is

Infrastructure-as-code for the racing telemetry server. Provisions a DigitalOcean droplet with OpenTofu and configures it with Ansible.

## Stack

- **Ubuntu 24.04** on DigitalOcean (s-1vcpu-2gb)
- **PostgreSQL 16** + **TimescaleDB 2.x** — telemetry storage
- **Grafana** — dashboards at `/grafana/`
- **racetelem** — Go telemetry relay API
- **Caddy** — reverse proxy with automatic HTTPS
- **Tailscale** — admin/SSH access
- **UFW + fail2ban** — firewall and brute-force protection

## Prerequisites

- [Hermit](https://cashapp.github.io/hermit/) (manages `tofu` and `task` binaries)
- Python dependencies (`pip install -r requirements.txt`)
- A DigitalOcean account with an API token
- An SSH key added to DigitalOcean
- A Tailscale auth key (from the Tailscale admin console)
- Go toolchain (for cross-compiling racetelem)

## Quick start

See [DEPLOY.md](DEPLOY.md) for the full deployment walkthrough.

```
source bin/activate-hermit       # activate hermit environment
task --list                      # show available tasks
```

## Project structure

```
├── Taskfile.yml                 # Build + deploy orchestration
├── bin/                         # Hermit-managed tools (tofu, task)
├── infra/                   # OpenTofu — droplet + firewall
├── ansible/
│   ├── inventory/
│   │   ├── hosts.yml            # Generated from tofu output
│   │   └── group_vars/all/
│   │       ├── vars.yml         # Non-secret config
│   │       └── vault.yml        # Encrypted secrets (ansible-vault)
│   ├── playbooks/
│   │   ├── site.yml             # Full server setup
│   │   └── deploy-racetelem.yml # Quick binary redeploy
│   ├── roles/
│   │   ├── common/              # apt, UFW, fail2ban
│   │   ├── tailscale/           # Install + join tailnet
│   │   ├── postgresql/          # PG 16 + TimescaleDB + schema
│   │   ├── grafana/             # Install, plugins, provisioned datasource
│   │   ├── racetelem/           # Binary + systemd service
│   │   └── caddy/               # Reverse proxy, auto-HTTPS
│   └── files/
│       └── racetelem            # Pre-built linux binary (gitignored)
└── scripts/
    └── build-racetelem.sh       # Cross-compile helper
```

## Tasks

| Task | Description |
|------|-------------|
| `task build` | Cross-compile racetelem for linux/amd64 |
| `task infra-init` | Initialize OpenTofu |
| `task infra-plan` | Preview infrastructure changes |
| `task infra-apply` | Apply infrastructure changes |
| `task inventory` | Generate Ansible inventory from OpenTofu outputs |
| `task bootstrap` | First-time server setup (root user) |
| `task configure` | Full server configuration |
| `task deploy` | Build and deploy just the racetelem binary |
