# NetBox for Home Assistant

Bring NetBox’s full IPAM/DCIM toolkit to your Home Assistant instance with a single add-on. This package preloads the upstream NetBox Docker image together with the services it needs (PostgreSQL + Redis), so you can keep track of racks, prefixes, VLANs, and circuits right next to the rest of your smart-home stack.

## About

- **Self-contained stack** – PostgreSQL, Redis, NetBox, and housekeeping jobs run inside one managed container.
- **Secure by default** – database credentials, Django secrets, and API tokens are auto-generated and stored in `/data`.
- **Ready for updates** – pinned upstream NetBox image and GitHub Actions workflow produce multi-arch images for `amd64` and `aarch64`.
- **Supervisor friendly** – supports snapshots, watchdog, persistent storage, and the Home Assistant UI lifecycle controls.

Use the _Documentation_ tab for setup details, config examples, and troubleshooting tips. When you’re ready, click **Start** to launch NetBox, then open port `8000` (or Home Assistant ingress) to begin managing your network inventory.

## How it works

- **Container recipe.** `netbox/Dockerfile` layers gosu, PostgreSQL, Redis, and bundled plugins on top of the upstream NetBox image, then hands control to `addon-run.sh` (see `netbox/run.sh`) which supervises every service with extensive INFO/DEBUG logging.
- **Configuration plumbing.** `netbox/config.yaml` mirrors the Home Assistant options—including the new `debug_logging` flag—so translations (`netbox/translations/en.yaml`) populate the Supervisor UI with contextual help.
- **Automated builds.** `.github/workflows/build.yml` drives a per-architecture GHCR publish. Each matrix job now prints the detected add-on version, target platform, and upstream base image before pushing tags, making audits straightforward.
