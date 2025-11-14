# Home Assistant Add-on: NetBox

NetBox is the open-source IP address management (IPAM) and data-center infrastructure management (DCIM) platform. This add-on bundles the upstream NetBox Docker image together with PostgreSQL, Redis, housekeeping jobs, and a health check so you can keep your network inventory close to Home Assistant—all while pinning the upstream version, auto-generating secrets, and storing everything under `/data` for easy snapshots.

## Installation

1. Add this repository (`https://github.com/boecht/ha-addon-netbox`) to **Settings → Add-ons → Add-on Store → ⋮ → Repositories**.
2. Open **NetBox** in the store and click **Install**.
3. Review the **Configuration** tab. The defaults work for most installs, but you can tailor the options below before first boot.
4. Hit **Start**. The first boot initializes PostgreSQL, Redis, runs NetBox migrations, and reconciles the admin user. This can take a few minutes on ARM devices.
5. Open the Web UI on `http://<home-assistant-host>:8000/` (or expose via Ingress/reverse proxy) and sign in with the default admin credentials (`admin` / `admin`). Change them immediately inside NetBox.

## Configuration

Only a handful of options are exposed in the add-on UI. Everything else is generated automatically and stored in `/data/options.json`.

| Option                  | Required | Description                                                                                                                              |
| ----------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `reset_superuser`       | ➖       | Toggle to force the NetBox admin account back to `admin` / `admin` / `admin@example.com`. The flag resets itself after a successful run. |
| `allowed_hosts`         | ➖       | Defaults to `*` (all hosts). Override with explicit hostnames/IPs if you need stricter enforcement.                                      |
| `housekeeping_interval` | ➖       | Seconds between NetBox housekeeping runs (default `3600`).                                                                               |
| `enable_prometheus`     | ➖       | When `true`, enables NetBox’s Prometheus metrics endpoint at `/metrics`.                                                                 |
| `debug_logging`         | ➖       | Toggles verbose DEBUG logs from the supervisor script. Leave on while diagnosing issues; turn off for quieter Supervisor logs.          |
| `plugins`               | ➖       | List of Python module names for NetBox plugins that are already baked into the upstream image.                                           |
| `napalm_username`       | ✅*      | Username used by `netbox_napalm_plugin` when talking to devices over NAPALM. Required if the plugin stays enabled.                       |
| `napalm_password`       | ➖       | Matching password for the NAPALM username. Leave blank if your devices authenticate via SSH keys.                                       |
| `napalm_timeout`        | ➖       | Timeout (seconds) for all NAPALM interactions. Increase for high-latency or slow devices.                                               |

### Credentials & secrets

- Database name/user/password, Redis password, Django secret key, and API token are generated on first boot and saved under `/data`. You normally never need to change them.
- To override the generated secrets, stop the add-on, edit `/addon_configs/netbox/options.json`, and restart. Be careful—changing database credentials after NetBox has initialized can render the instance unusable.

## Data locations

| Path                   | Purpose                                       |
| ---------------------- | --------------------------------------------- |
| `/data/postgres`       | PostgreSQL cluster (databases, WAL).          |
| `/data/redis`          | Redis append-only files and RDB snapshots.    |
| `/data/netbox/media`   | Uploaded images/files.                        |
| `/data/netbox/reports` | NetBox report scripts.                        |
| `/data/netbox/scripts` | Custom automation scripts.                    |
| `/root/.cache/netbox`  | Temporary pip caches from the upstream image. |

Use Home Assistant snapshots or copy `/addon_local/netbox/` to back up NetBox. Restoring a snapshot brings back the database, Redis state, and media.

## Networking

- Default TCP port: **8000** (plain HTTP). Change the port mapping from the add-on Info tab if needed or front it with an Nginx/Caddy proxy for HTTPS.
- Health check: `http://[HOST]:[PORT:8000]/health/` (used by the Supervisor watchdog).
- Redis/PostgreSQL listen on localhost inside the container and are not exposed.

## Updates

- The add-on pins the NetBox Docker tag for reproducibility. When a new NetBox release ships, we bump `netbox/config.yaml` and rebuild both `netbox-amd64` and `netbox-aarch64` images via GitHub Actions.
- To upgrade, install the new add-on version from the Store. The entrypoint runs migrations automatically before serving traffic.
- On every start the add-on waits for PostgreSQL to become available, applies any pending NetBox migrations, and runs the standard housekeeping commands before launching the services.

## Troubleshooting

| Symptom                                 | Suggested action                                                                                                                                          |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Locked out of NetBox admin account      | Toggle `reset_superuser`, restart the add-on once, then log in with `admin` / `admin`.                                                                    |
| Web UI loads but login fails            | Confirm you’re using the NetBox admin credentials you set inside the Web UI. If in doubt, toggle `reset_superuser` and restart once to restore `admin` / `admin`. |
| “Database connection refused” errors    | Check Supervisor logs for PostgreSQL initialization messages. Deleting `/data/postgres` forces a re-init (you’ll lose data).                              |
| Watchdog keeps restarting the add-on    | Visit `/health/` in your browser. If it returns anything but `200 OK`, inspect `/config/netbox.log` (Supervisor Logs tab) for migration or plugin errors. |
| Need to expose NetBox via HTTPS/Ingress | Place a reverse proxy (e.g., Nginx Proxy Manager add-on) in front of port 8000 or configure HA’s Ingress with your own auth.                              |

## Support & feedback

- Open issues or feature requests at [github.com/boecht/ha-addon-netbox](https://github.com/boecht/ha-addon-netbox/issues).
- Discuss NetBox features on the [NetBox Community Slack](https://netboxlabs.com/community/slack) or forums.
- For Home Assistant-specific questions, visit the [Home Assistant Community Forum](https://community.home-assistant.io) or Discord.

Enjoy having your entire network inventory managed right inside Home Assistant!
