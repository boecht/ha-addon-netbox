# Home Assistant Add-on: NetBox

NetBox is the open-source IP address management (IPAM) and data-center infrastructure management (DCIM) platform. This add-on bundles the upstream NetBox Docker image together with PostgreSQL, Redis, housekeeping jobs, and a health check so you can keep your network inventory close to Home Assistant—all while pinning the upstream version, auto-generating secrets, and storing everything under `/data` for easy snapshots.

## Installation

1. Add this repository (`https://github.com/boecht/ha-addon-netbox`) to **Settings → Add-ons → Add-on Store → ⋮ → Repositories**.
2. Open **NetBox** in the store and click **Install**.
3. Switch to the **Configuration** tab and set a strong `superuser_password` (required). Adjust other options if needed.
4. Hit **Start**. The first boot initializes PostgreSQL, Redis, runs NetBox migrations, and reconciles the admin user. This can take a few minutes on ARM devices.
5. Open the Web UI on `http://<home-assistant-host>:8000/` (or expose via Ingress/reverse proxy) and sign in with the superuser credentials you configured.

## Configuration

Only a handful of options are exposed in the add-on UI. Everything else is generated automatically and stored in `/data/options.json`.

| Option | Required | Description |
| ------ | -------- | ----------- |
| `superuser_username` | ✅ | Django superuser name kept in sync on each boot (default `admin`). |
| `superuser_email` | ✅ | Contact address shown in NetBox. |
| `superuser_password` | ✅ | Password for the NetBox superuser (defaults to `admin`). Change it as soon as you log in. |
| `allowed_hosts` | ➖ | Defaults to `*` (all hosts). Override with explicit hostnames/IPs if you need stricter enforcement. |
| `housekeeping_interval` | ➖ | Seconds between NetBox housekeeping runs (default `3600`). |
| `enable_prometheus` | ➖ | When `true`, enables NetBox’s Prometheus metrics endpoint at `/metrics`. |
| `plugins` | ➖ | List of Python module names for NetBox plugins that are already baked into the upstream image. |

### Advanced/implicit settings

- Database name/user/password, Redis password, Django secret key, and API token are generated on first boot and saved under `/data`. You normally never need to change them.
- To override the generated secrets, stop the add-on, edit `/addon_configs/<slug>/options.json`, and restart. Be careful—changing database credentials after NetBox has initialized can render the instance unusable.

## Data locations

| Path | Purpose |
| ---- | ------- |
| `/data/postgres` | PostgreSQL cluster (databases, WAL). |
| `/data/redis` | Redis append-only files and RDB snapshots. |
| `/data/netbox/media` | Uploaded images/files. |
| `/data/netbox/reports` | NetBox report scripts. |
| `/data/netbox/scripts` | Custom automation scripts. |
| `/root/.cache/netbox` | Temporary pip caches from the upstream image. |

Use Home Assistant snapshots or copy `/addon_local/netbox/` to back up NetBox. Restoring a snapshot brings back the database, Redis state, and media.

## Networking

- Default TCP port: **8000** (plain HTTP). Change the port mapping from the add-on Info tab if needed or front it with an Nginx/Caddy proxy for HTTPS.
- Health check: `http://[HOST]:[PORT:8000]/health/` (used by the Supervisor watchdog).
- Redis/PostgreSQL listen on localhost inside the container and are not exposed.

## Updates

- The add-on pins the NetBox Docker tag for reproducibility. When a new NetBox release ships, we bump `netbox/config.yaml` and rebuild both `netbox-amd64` and `netbox-aarch64` images via GitHub Actions.
- To upgrade, install the new add-on version from the Store. The entrypoint runs migrations automatically before serving traffic.

## Troubleshooting

| Symptom | Suggested action |
| ------- | ---------------- |
| Add-on refuses to start and logs “superuser_password is required” | Set a password on the Configuration tab, save, and start again. |
| Web UI loads but login fails | Ensure the `superuser_username`/`password` options match what you expect; the entrypoint resets the Django superuser on each boot. |
| “Database connection refused” errors | Check Supervisor logs for PostgreSQL initialization messages. Deleting `/data/postgres` forces a re-init (you’ll lose data). |
| Watchdog keeps restarting the add-on | Visit `/health/` in your browser. If it returns anything but `200 OK`, inspect `/config/netbox.log` (Supervisor Logs tab) for migration or plugin errors. |
| Need to expose NetBox via HTTPS/Ingress | Place a reverse proxy (e.g., Nginx Proxy Manager add-on) in front of port 8000 or configure HA’s Ingress with your own auth. |

## Support & feedback

- Open issues or feature requests at [github.com/boecht/ha-addon-netbox](https://github.com/boecht/ha-addon-netbox/issues).
- Discuss NetBox features on the [NetBox Community Slack](https://netboxlabs.com/community/slack) or forums.
- For Home Assistant-specific questions, visit the [Home Assistant Community Forum](https://community.home-assistant.io) or Discord.

Enjoy having your entire network inventory managed right inside Home Assistant!
