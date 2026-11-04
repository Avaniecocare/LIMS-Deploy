# LIMS-Deploy

Everything needed to run the LIMS for a customer: production Compose files, a reverse proxy with TLS, and scripts for provisioning, deployment, migrations, backup, restore, upgrade and rollback. It contains no application source code.

This repository is public. `clients/` holds only `_template/` and fictional examples. Real env files, branding, version pins, secrets, customer data and backups stay outside it, and every script takes their location through `--client-dir`.

- [DEPLOYMENT.md](DEPLOYMENT.md): how a server is set up and operated
- [ONBOARDING.md](ONBOARDING.md): adding a new company
- [DECISIONS.md](DECISIONS.md): choices behind this setup

Git hooks: `git config core.hooksPath .githooks` (needs gitleaks).
