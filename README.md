# LIMS-Deploy

Everything needed to run the LIMS for a customer: production Compose files, reverse proxy with TLS, and scripts for provisioning, deployment, migrations, backup, restore, upgrade and rollback. It contains no application source code.

This repository is public. `clients/` holds only `_template/` and fictional examples. Real env files, branding, version pins, secrets, customer data and backups stay outside it, and scripts take their location as an input.
