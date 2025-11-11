# NetBox for Home Assistant

Bring NetBox’s full IPAM/DCIM toolkit to your Home Assistant instance with a single add-on. This package preloads the upstream NetBox Docker image together with the services it needs (PostgreSQL + Redis), so you can keep track of racks, prefixes, VLANs, and circuits right next to the rest of your smart-home stack.

## Highlights

- **Self-contained stack** – PostgreSQL, Redis, NetBox, and housekeeping jobs run inside one managed container.
- **Secure by default** – database credentials, Django secrets, and API tokens are auto-generated and stored in `/data`.
- **Ready for updates** – pinned upstream NetBox image and GitHub Actions workflow produce multi-arch images for `amd64` and `aarch64`.
- **Supervisor friendly** – supports snapshots, watchdog, persistent storage, and the Home Assistant UI lifecycle controls.

First launch uses the `admin` / `admin` NetBox superuser so you can hop in immediately—just change it after logging in.

Use the *Documentation* tab for setup details, config examples, and troubleshooting tips. When you’re ready, click **Start** to launch NetBox, then open port `8000` (or Home Assistant ingress) to begin managing your network inventory.
