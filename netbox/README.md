# NetBox Add-on Development Notes

This directory contains the Home Assistant add-on definition for NetBox. Key files:

- `Dockerfile` – extends the upstream NetBox container and installs PostgreSQL, Redis, gosu, jq, and tini.
- `run.sh` – orchestrates PostgreSQL initialization, Redis startup, and the upstream NetBox entrypoint.
- `config.yaml` / `build.yaml` – Supervisor metadata and build configuration.
- `DOCS.md` – user-facing instructions surfaced inside Home Assistant.

## Local Testing

1. Build the add-on image locally:

   ```bash
   docker build -t ha-netbox-dev -f netbox/Dockerfile netbox
   ```

2. Run it with a bind mount for `/data` to persist the embedded PostgreSQL cluster:

   ```bash
   docker run --rm -it \
     -v $(pwd)/sandbox-data:/data \
     -p 8000:8000 \
     -e CONFIG_PATH=/data/options.json \
     ha-netbox-dev
   ```

   Craft an `options.json` file that mirrors the Supervisor options schema.

## Updating the Base Image

- Edit `netbox/build.yaml` to bump `ghcr.io/netbox-community/netbox:<tag>`.
- Mention the upstream NetBox + NetBox Docker versions in `CHANGELOG.md`.
- Run the GitHub Actions workflow or `docker buildx bake` locally to push multi-arch images.

## Code Style

- Bash scripts are `set -euo pipefail` and prefer helper functions over inline subshells.
- Keep all persistent data under `/data` so Supervisor backups pick it up.
- Keep secrets in files within `/data` and avoid logging their values.

## TODOs / Ideas

- Support optional external PostgreSQL/Redis connections (skip embedded services when disabled).
- Add scripted NetBox backup/restore helpers.
- Integrate TLS termination via Caddy or Traefik for direct WAN exposure.
