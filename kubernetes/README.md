# Kubernetes

One company per namespace, each with its own settings, secrets, cache, identity, limits and network. Plain manifests with Kustomize, which `kubectl` has built in. Needs Kubernetes 1.30 or later, and a network plugin that enforces NetworkPolicy (Terraform turns this on in EKS; without it the isolation rules are ignored without a word).

| Folder | What it is |
| --- | --- |
| `base/` | API, worker, screens, migrations, scaling, disruption budgets, network rules, limits |
| `components/redis/` | This company's own cache |
| `components/aws/` | EKS: secrets from Secrets Manager, the load balancer's target groups, database and Pod Identity network rules |
| `cluster/` | Once per EKS cluster: encrypted disks, and the secret store |
| `create-database.sh` | A company's database and roles on RDS |
| `overlays/example/` | A fictional company, to copy |
| `overlays/local/` | For `check.sh` only |
| `deploy.sh` | Installs or upgrades one company |
| `check.sh` | Runs all this on a throwaway cluster and checks it by use |

This repository is public. Real overlays live outside it.

## Add a company

1. On AWS, Terraform makes its bucket, secrets, identity and routing, and `create-database.sh` its database: [docs/aws/companies.md](../docs/aws/companies.md). Its two secrets hold:

   | Secret | Keys |
   | --- | --- |
   | `lims/prod/<slug>/app` | `DATABASE_URL` (role `lims_<slug>_app`), `REDIS_PASSWORD`, `REDIS_URL`, `SESSION_SECRET`, `SETUP_TOKEN`, and by hand `SMTP_USER`, `SMTP_PASSWORD`, `LICENCE`, `WHATSAPP_*`, `EINVOICE_*`, `AI_API_KEY` |
   | `lims/prod/<slug>/migrate` | `MIGRATION_DATABASE_URL` (role `lims_<slug>_owner`) |

   Leave `S3_ACCESS_KEY` and `S3_SECRET_KEY` out: the pods use Pod Identity.

2. Copy `overlays/example`, change `lims-example` in `kustomization.yaml` and `namespace.yaml`, and fill in `company.properties`. Point `resources` and `components` at this folder.
3. Amazon's database certificates are signed by its own authority. Once per namespace:

   ```sh
   curl -fsSO https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
   kubectl -n lims-<slug> create configmap rds-ca --from-file=global-bundle.pem
   ```

4. `kubernetes/deploy.sh <overlay>`
5. Point DNS at the load balancer, and open the app with the setup token.

## Upgrade and roll back

Change `newTag` and run `deploy.sh` again. Migrations run first, as the table owner, in a Job that alone holds that password. If they fail, nothing running is touched. If the new version does not become ready, the previous one is put back. Pods are replaced one at a time, so nobody is interrupted.

Migrations only go forward. To go further back than the last version, restore a database snapshot from before the upgrade; anything entered since is lost. Take one before each upgrade.

Use exact tags, or digests. Change a setting in `company.properties` and run `deploy.sh`: pods restart with it. After a secret changes, `kubectl -n <namespace> rollout restart deployment/api deployment/worker`.

## Security

- Pods run as a numbered user with a read-only filesystem, no Linux capabilities and no Kubernetes token, under the `restricted` pod security standard.
- Nothing may connect in or out except what is listed in `base/network-policy.yaml`. Private addresses and the machine's metadata service are not reachable from the app.
- The app connects to the database as a role that owns no tables. Only the migrate Job has the owner's password.
- Keep Kubernetes secrets encrypted with your own KMS key (Terraform turns this on).

## Scaling

The API grows from 2 to 6 copies and the worker from 1 to 3, by CPU (needs metrics-server). Each API copy holds up to 13 database connections and each worker the same: check the database's limit before raising them. The cache is one pod with a disk; if its machine fails, people wait for it to move, and sign-ins and queued work survive.

## Monitoring

See [../monitoring](../monitoring/README.md).

## Checking changes

```sh
kubectl kustomize overlays/example | kubeconform -strict -ignore-missing-schemas -summary
K3S_IMAGE=rancher/k3s:v1.36.6-k3s1 ./check.sh     # needs images tagged k8s-test
```
