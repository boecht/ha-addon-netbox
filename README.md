# NetBox Home Assistant Add-on Repository

This repository hosts the NetBox Home Assistant add-on (`netbox/`). The add-on bundles the upstream NetBox Docker image together with PostgreSQL and Redis so that Home Assistant power users can deploy a fully featured IPAM/DCIM stack without managing multiple containers.

## Layout

```text
.
├── netbox/
│   ├── Dockerfile        # Extends ghcr.io/netbox-community/netbox
│   ├── run.sh            # Entry script (PostgreSQL + Redis + NetBox)
│   ├── config.yaml       # Supervisor metadata & schema
│   ├── build.yaml        # Build args & base image pin
│   ├── DOCS.md           # User-facing docs rendered in HA UI
│   └── README.md         # Developer notes and local testing tips
├── CHANGELOG.md
├── repository.json
├── .addons.yml
└── .github/workflows/build.yml
```

## Getting Started

1. Fork/clone this repository.
2. Update `repository.json` with your GitHub URL if you plan to publish under a different namespace.
3. Push changes to `main` and create a tag when you want Supervisor users to receive an update.
4. Add the repository URL to **Settings → Add-ons → Repositories** inside Home Assistant.

## Development Workflow

- **Build** – run `docker build -t ha-netbox-dev -f netbox/Dockerfile netbox`.
- **Lint** – shell scripts are POSIX/Bash; run `shellcheck netbox/run.sh` when available.
- **Test** – mount a temp directory to `/data` and provide an `options.json` file to simulate Supervisor.
- **Publish** – the GitHub Actions workflow builds multi-arch images (amd64 + arm64) and pushes to `ghcr.io/boecht/ha-addon-netbox/netbox-{arch}`.

For full configuration, upgrade, and troubleshooting guidance refer to `netbox/DOCS.md`.
