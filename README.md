# NetBox Home Assistant Add-on Repository

This repository hosts the NetBox Home Assistant add-on (`netbox/`). The add-on bundles the upstream NetBox Docker image together with PostgreSQL and Redis so that Home Assistant power users can deploy a fully featured IPAM/DCIM stack without managing multiple containers.

[![Add repository on my Home Assistant][repository-badge]][repository-url]

## Layout

```text
.
├── .github/workflows/build.yml     # Multi-arch build + publish pipeline
├── netbox/
│   ├── apparmor.txt                # Add-on AppArmor profile
│   ├── build.yaml                  # Base image pin per architecture
│   ├── CHANGELOG.md                # User-facing release notes rendered in HA
│   ├── config.yaml                 # Supervisor metadata & schema (includes ingress/port config)
│   ├── Dockerfile                  # Extends ghcr.io/netbox-community/netbox
│   ├── DOCS.md                     # Documentation tab content
│   ├── icon.png / logo.png         # Store badges/icons
│   ├── README.md                   # Add-on specific developer notes
│   ├── run.sh                      # Entry script (PostgreSQL + Redis + NetBox)
│   └── translations/               # Localized strings for the HA UI
├── scripts/sync_versions.py        # Keeps Dockerfile/build.yaml aligned with versions.yaml
├── .addons.yml                     # Home Assistant add-on repository index
├── repository.json                 # Supervisor store metadata for this repo
└── versions.yaml                   # Source of truth for NetBox + plugin pins
```

## Contributing

1. Fork/clone this repository.
2. Update `repository.json` with your GitHub URL if you plan to publish under a different namespace.
3. Run `python3 scripts/sync_versions.py` after tweaking `versions.yaml` or plugin pins so `netbox/Dockerfile`, `netbox/build.yaml`, and docs stay in sync.
4. Push changes to `main`; the workflow auto-builds and tags images based on `netbox/config.yaml`.
5. (Optional) Add the repository URL to **Settings → Add-ons → Repositories** inside Home Assistant for local testing.

## Development Workflow

- **Build** – run `docker build -t ha-netbox-dev -f netbox/Dockerfile netbox`.
- **Lint** – shell scripts are POSIX/Bash; run `shellcheck netbox/run.sh` when available.
- **Test** – mount a temp directory to `/data` and provide an `options.json` file to simulate Supervisor.
- **Publish** – the GitHub Actions workflow builds multi-arch images (amd64 + arm64) and pushes to `ghcr.io/boecht/ha-addon-netbox/netbox-{arch}`.

For full configuration, upgrade, and troubleshooting guidance refer to `netbox/DOCS.md`.

[repository-badge]: <https://img.shields.io/badge/Add%20repository%20to%20my-Home%20Assistant-41BDF5?logo=home-assistant&style=for-the-badge>
[repository-url]: <https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fboecht%2Fha-addon-netbox>
