# NetBox Home Assistant Add-on

Run the upstream NetBox Docker image together with PostgreSQL and Redis inside a single Home Assistant Supervisor add-on. This bundle is aimed at lab or homelab environments that prefer to keep IPAM/DCIM data close to Home Assistant while still following upstream NetBox best practices.

## Features at a Glance

- Uses the official `ghcr.io/netbox-community/netbox:v4.4.3-3.4.1` base image.
- Launches PostgreSQL 15 and Redis inside the same container with persistent volumes under `/data`.
- Auto-generates database, API token, and Django secret keys if you leave the option blank.
- Runs upstream NetBox entrypoint (Gunicorn + RQ worker + housekeeping scripts) after seeding the local services.
- Exposes NetBox on TCP port 8000 (<http://homeassistant.local:8000> by default) plus an HTTP health check endpoint for the watchdog.

## Installation

1. Add the repository URL (`https://github.com/boecht/ha-addon-netbox`) to your Home Assistant Supervisor -> Add-on Store -> Repositories.
2. Locate **NetBox** in the store, click **Install**, then review the configuration section before starting the add-on.
3. On first start, the add-on initializes PostgreSQL, creates the NetBox database/schema, and runs NetBox migrations. This may take a few minutes on arm64 devices.

## Configuration

| Option | Description |
| ------ | ----------- |
| `db_name`, `db_user`, `db_password` | Internal PostgreSQL database name/user/password. If `db_password` is left empty a random password is generated and stored in `/data/.db_password`.
| `superuser_username`, `superuser_email`, `superuser_password` | Credentials for the NetBox Django superuser. The password is required and should be at least 12 characters. The add-on reconciles this user on every boot.
| `superuser_api_token` | Optional initial API token for the superuser. Auto-generated and persisted if blank.
| `secret_key` | Optional Django secret key. Auto-generated and persisted if blank.
| `allowed_hosts` | List of hostnames/IPs that should be accepted by NetBox (mirrors Django `ALLOWED_HOSTS`). Include any reverse proxies or ingress hostnames you plan to use.
| `time_zone` | Passed to NetBox via `TZ`.
| `housekeeping_interval` | Seconds between NetBox housekeeping runs (default 3600).
| `enable_prometheus` | Enables NetBox’s Prometheus metrics flag, which exposes `/metrics`.
| `plugins` | JSON-style list of plugin module names. Plugins must already be baked into the upstream image.

> **Tip:** You can edit `options.json` directly (Supervisor backups) to copy the auto-generated secrets if you leave password fields blank initially.

## Data Persistence

- PostgreSQL data lives in `/data/postgres`.
- Redis append-only logs are stored in `/data/redis`.
- NetBox media/reports/scripts live in `/data/netbox`.

Use Home Assistant’s backup system or copy the `/addon_local/netbox/` folder to safeguard the database and media files.

## Networking

- Default port mapping exposes NetBox on `8000/tcp`. Adjust via Supervisor panel if needed.
- The add-on runs entirely on the HA docker network. Use the built-in reverse proxy / ingress if you need TLS termination.

## Updates

1. Bump the version in `netbox/config.yaml` and `CHANGELOG.md` when changing user-visible behavior.
2. GitHub Actions workflow (`.github/workflows/build.yml`) builds multi-arch images and pushes to `ghcr.io/boecht/ha-addon-netbox/netbox-{arch}`.
3. Users will see updates once you publish a new GitHub release tag.

## Troubleshooting

- **Container restarts immediately** – ensure you provided `superuser_password`. The add-on refuses to start without it.
- **NetBox can’t connect to the database** – delete `/data/postgres` only if you intentionally want to reset the database. Otherwise check Supervisor logs for PostgreSQL errors.
- **Health check offline** – verify `http://<HomeAssistantHost>:8000/health/` returns `200`. The Supervisor watchdog relies on this URL.
- **Plugins** – because the add-on reuses the upstream NetBox image, additional plugin wheels must be added by extending this repository and rebuilding the image.

## Known Limitations

- Running PostgreSQL and Redis inside the NetBox container is convenient but not horizontally scalable. For large deployments consider external services.
- Backups are currently manual; plan Supervisor backups around major NetBox upgrades.
