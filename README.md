# LIMS-Deploy

By [Taravik Private Limited](https://taravik.com). Proprietary: see [LICENSE](LICENSE).

Everything needed to run the LIMS for a customer: production Compose files, a reverse proxy with TLS, and scripts for provisioning, deployment, migrations, backup, restore, upgrade and rollback. It contains no application source code.

This repository is public. `clients/` holds only `_template/` and fictional examples. Real env files, branding, version pins, secrets, customer data and backups stay outside it, and every script takes their location through `--client-dir`.

- [docker-compose/](docker-compose/README.md): a trial or small installation, started with one command
- [kubernetes/](kubernetes/README.md): production on Kubernetes, a namespace per company
- [terraform/](terraform/README.md): AWS, as [one server](terraform/server/README.md) (about 85-165 US dollars a month) or on Kubernetes
- [monitoring/](monitoring/README.md): metrics and alerts
- [DEPLOYMENT.md](DEPLOYMENT.md): how a server for several companies is set up and operated
- [ONBOARDING.md](ONBOARDING.md): adding a new company
- [DECISIONS.md](DECISIONS.md): choices behind this setup
- [docs/guides/](docs/guides/README.md): administrator guide and a user guide for each role

Provisioning installs a nightly backup of each company's database, files and settings, which can be encrypted (age or gpg) and copied off-site; see [DEPLOYMENT.md](DEPLOYMENT.md#backups).

The `Checks` workflow runs the trial package, `scripts/lifecycle-check.sh` and the Kubernetes check on GitHub, on images it builds from source. `scripts/lifecycle-check.sh` runs the whole operational lifecycle on two fictional companies, and `scripts/white-label-check.sh` confirms one image serves both.

Git hooks: `git config core.hooksPath .githooks` (needs gitleaks).
