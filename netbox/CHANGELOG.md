# Changelog

## [1.0.1] - 2025-11-29

- Fixed PostgreSQL path resolution that caused permission errors during startup.
- Fixed netbox-ping first-boot migration.

## [1.0.0] - 2025-11-16

- Ships NetBox v4.4.6 (container tag `v4.4.6-3.4.2`).
- Bundled plugins:
  - [`netbox-napalm-plugin`](https://pypi.org/project/netbox-napalm-plugin/) v0.3.3
  - [`netbox-ping`](https://pypi.org/project/netbox-ping/) v0.54
  - [`netbox-topology-views`](https://pypi.org/project/netbox-topology-views/) v4.4.0
